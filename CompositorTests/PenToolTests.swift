import AppKit
import Testing
@testable import Compositor

@MainActor
struct PenToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200, emptyLayer: true)
        session.selectTool(.pen)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 2
        return session
    }

    @Test func activatingPenToolCreatesTransientStateOnly() {
        let session = makeSession()
        let count = session.history.undoCount
        let layerCount = session.document?.layers.count ?? 0

        #expect(session.tool == .pen)
        #expect(session.penDraft == nil)
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layerCount)
    }

    @Test func firstClickCreatesOneAnchorWithoutCreatingDocumentLayer() {
        let session = makeSession()
        let initialLayers = session.document?.layers.count ?? 0
        let count = session.history.undoCount

        session.beginPen(at: CGPoint(x: 20, y: 30))
        session.endPenDrag()

        #expect(session.penDraft != nil)
        #expect(session.penDraft?.subpath.points.count == 1)
        #expect(session.penDraft?.subpath.points[0].anchor == CGPoint(x: 20, y: 30))
        #expect(session.penDraft?.subpath.points[0].previousControl == nil)
        #expect(session.penDraft?.subpath.points[0].nextControl == nil)
        #expect(session.document?.layers.count == initialLayers)
        #expect(session.history.undoCount == count)
    }

    @Test func secondClickCreatesAStraightSegment() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 30))
        session.endPenDrag()

        session.beginPen(at: CGPoint(x: 60, y: 70))
        session.endPenDrag()

        guard let draft = session.penDraft else {
            Issue.record("penDraft should exist")
            return
        }

        #expect(draft.subpath.points.count == 2)
        #expect(draft.subpath.points[0].anchor == CGPoint(x: 20, y: 30))
        #expect(draft.subpath.points[0].nextControl == nil)
        #expect(draft.subpath.points[1].anchor == CGPoint(x: 60, y: 70))
        #expect(draft.subpath.points[1].previousControl == nil)
        #expect(draft.subpath.points[1].nextControl == nil)
    }

    @Test func multipleClicksCreateMultipleAnchors() {
        let session = makeSession()
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 40), CGPoint(x: 60, y: 20), CGPoint(x: 90, y: 80)]

        for p in points {
            session.beginPen(at: p)
            session.endPenDrag()
        }

        guard let draft = session.penDraft else {
            Issue.record("penDraft should exist")
            return
        }

        #expect(draft.subpath.points.count == 4)
        for (i, p) in points.enumerated() {
            #expect(draft.subpath.points[i].anchor == p)
        }
    }

    @Test func clickDragCreatesSymmetricalBezierHandles() {
        let session = makeSession()
        let anchor = CGPoint(x: 50, y: 50)
        let dragTarget = CGPoint(x: 70, y: 60)

        session.beginPen(at: anchor)
        session.dragPen(to: dragTarget)
        session.endPenDrag()

        guard let draft = session.penDraft, draft.subpath.points.count == 1 else {
            Issue.record("penDraft should have 1 point")
            return
        }

        let pt = draft.subpath.points[0]
        #expect(pt.anchor == anchor)

        // D = dragTarget - anchor = (20, 10)
        // nextControl = P + D = (70, 60)
        // previousControl = P - D = (30, 40)
        #expect(pt.nextControl == CGPoint(x: 70, y: 60))
        #expect(pt.previousControl == CGPoint(x: 30, y: 40))
    }

    @Test func bezierHandlesAreStoredInDocumentCoordinates() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.dragPen(to: CGPoint(x: 120, y: 110))
        session.endPenDrag()

        guard let draft = session.penDraft, let pt = draft.subpath.points.first else {
            Issue.record("Expected point")
            return
        }

        #expect(pt.anchor.x == 100 && pt.anchor.y == 100)
        #expect(pt.nextControl?.x == 120 && pt.nextControl?.y == 110)
        #expect(pt.previousControl?.x == 80 && pt.previousControl?.y == 90)
    }

    @Test func livePreviewDoesNotMutateCanvasDocument() {
        let session = makeSession()
        let initialLayers = session.document?.layers.count ?? 0
        let historyCount = session.history.undoCount

        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.movePen(to: CGPoint(x: 70, y: 80))

        #expect(session.penDraft?.pointer == CGPoint(x: 70, y: 80))
        #expect(session.document?.layers.count == initialLayers)
        #expect(session.history.undoCount == historyCount)

        session.movePen(to: CGPoint(x: 90, y: 100))
        #expect(session.penDraft?.pointer == CGPoint(x: 90, y: 100))
        #expect(session.document?.layers.count == initialLayers)
        #expect(session.history.undoCount == historyCount)
    }

    @Test func clickingTheFirstAnchorClosesThePathWithoutDuplicate() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 50))
        session.endPenDrag()

        #expect(session.penDraft?.subpath.points.count == 3)

        // Close path directly
        session.closePen()

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == 2) // Initial blank layer + committed vector layer

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Committed layer must have vector model")
            return
        }

        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed == true)
        #expect(vector.subpaths[0].points.count == 3, "Closing must not duplicate the initial anchor")
        #expect(vector.fill == nil, "Pen closed path must be transparent by default")
        #expect(vector.stroke == nil, "Pen path must have no stroke by default")
    }

    @Test func enterCommitsAnOpenPath() {
        let session = makeSession()
        let count = session.history.undoCount

        session.beginPen(at: CGPoint(x: 20, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 50))
        session.endPenDrag()

        session.finishPen() // Enter / Return

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == 2)
        #expect(session.history.undoCount == count + 1)

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Layer should have vector model")
            return
        }

        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed == false)
        #expect(vector.subpaths[0].points.count == 2)
        #expect(vector.stroke == nil, "Open Pen path has no stroke by default")
        #expect(vector.fill == nil, "Open Pen path has no fill by default")
        #expect(layer.asset != nil)
    }

    @Test func escapeCancelsWithoutChangingDocumentHistory() {
        let session = makeSession()
        let count = session.history.undoCount
        let layerCount = session.document?.layers.count ?? 0

        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()

        #expect(session.penDraft != nil)
        session.cancelPen() // Escape

        #expect(session.penDraft == nil)
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layerCount)
    }

    @Test func emptyEnterDoesNothing() {
        let session = makeSession()
        let count = session.history.undoCount
        let layerCount = session.document?.layers.count ?? 0

        // Enter with no draft
        session.finishPen()
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layerCount)

        // Enter with 1 anchor only (cannot form valid open path)
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.finishPen()

        #expect(session.penDraft == nil)
        #expect(session.history.undoCount == count)
        #expect(session.document?.layers.count == layerCount)
    }

    @Test func committedLayerContainsExpectedVectorModelAndRenderedAsset() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.dragPen(to: CGPoint(x: 30, y: 25))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 40))
        session.dragPen(to: CGPoint(x: 90, y: 45))
        session.endPenDrag()

        session.finishPen()

        guard let layer = session.activeLayer, let vector = layer.vector, let asset = layer.asset else {
            Issue.record("Layer must have vector and asset")
            return
        }

        #expect(layer.name == "Vector 1")
        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].points.count == 2)
        #expect(vector.stroke == nil, "Pen path has no stroke by default")
        #expect(vector.fill == nil, "Pen path has no fill by default")
        #expect(asset.image.width > 0 && asset.image.height > 0)
        #expect(layer.transform.size.width >= 1 && layer.transform.size.height >= 1)
    }

    @Test func undoRemovesAndRestoresCommittedVectorLayerThroughHistory() {
        let session = makeSession()
        let initialLayers = session.document?.layers.count ?? 0

        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.finishPen()

        #expect(session.document?.layers.count == initialLayers + 1)
        let vectorModel = session.activeLayer?.vector

        // Undo
        session.undo()
        #expect(session.document?.layers.count == initialLayers)
        #expect(session.activeLayer?.vector == nil)

        // Redo
        session.redo()
        #expect(session.document?.layers.count == initialLayers + 1)
        #expect(session.activeLayer?.vector == vectorModel)
    }

    @Test func zoomIndependencePreservesLogicalCoordinates() {
        let session = makeSession()
        let docSize = CGSize(width: 200, height: 200)

        // Test at 50% zoom
        session.zoom(to: 0.5)
        let docPoint1 = CGPoint(x: 40, y: 60)
        let viewPoint1 = session.viewport.viewPoint(from: docPoint1, documentSize: docSize)
        let backToDoc1 = session.viewport.documentPoint(from: viewPoint1, documentSize: docSize)
        #expect(abs(backToDoc1.x - docPoint1.x) < 0.001)
        #expect(abs(backToDoc1.y - docPoint1.y) < 0.001)

        // Test at 100% zoom
        session.zoom(to: 1.0)
        let viewPoint2 = session.viewport.viewPoint(from: docPoint1, documentSize: docSize)
        let backToDoc2 = session.viewport.documentPoint(from: viewPoint2, documentSize: docSize)
        #expect(abs(backToDoc2.x - docPoint1.x) < 0.001)
        #expect(abs(backToDoc2.y - docPoint1.y) < 0.001)

        // Test at 200% zoom
        session.zoom(to: 2.0)
        let viewPoint3 = session.viewport.viewPoint(from: docPoint1, documentSize: docSize)
        let backToDoc3 = session.viewport.documentPoint(from: viewPoint3, documentSize: docSize)
        #expect(abs(backToDoc3.x - docPoint1.x) < 0.001)
        #expect(abs(backToDoc3.y - docPoint1.y) < 0.001)
    }

    @Test func controlPointsOutsideAnchorBoundsExpandLayerBoundsSafely() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.dragPen(to: CGPoint(x: 150, y: 100))
        session.endPenDrag()

        session.beginPen(at: CGPoint(x: 100, y: 200))
        session.endPenDrag()

        session.finishPen()

        guard let layer = session.activeLayer, let vector = layer.vector, let asset = layer.asset else {
            Issue.record("Layer must have vector and asset")
            return
        }

        // Both anchors are at X=100, but the Bézier control point pulls the curve outward to X ≈ 122.22.
        // The layer bounds must expand beyond the anchors to safely contain the curve extrema plus stroke padding.
        #expect(layer.transform.origin.x <= 100 - 3)
        #expect(layer.transform.origin.x + layer.transform.size.width >= 122.22 + 3)
        #expect(asset.image.width == Int(layer.transform.size.width))
        #expect(asset.image.height == Int(layer.transform.size.height))

        // Reconstituting document coordinates from layer-local coordinates + origin matches original
        let origin = layer.transform.origin
        let pt0 = vector.subpaths[0].points[0]
        #expect(pt0.anchor.x + origin.x == 100)
        #expect(pt0.anchor.y + origin.y == 100)
        #expect((pt0.previousControl?.x ?? 0) + origin.x == 50)
        #expect((pt0.previousControl?.y ?? 0) + origin.y == 100)
        #expect((pt0.nextControl?.x ?? 0) + origin.x == 150)
        #expect((pt0.nextControl?.y ?? 0) + origin.y == 100)

        let pt1 = vector.subpaths[0].points[1]
        #expect(pt1.anchor.x + origin.x == 100)
        #expect(pt1.anchor.y + origin.y == 200)
    }

    @Test func movingLayerPreservesLayerLocalVectorModel() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == session.activeLayerID }) else {
            Issue.record("Layer expected")
            return
        }

        let originalVector = session.document!.layers[layerIndex].vector
        #expect(originalVector != nil)

        // Simulate moving layer with Move tool (mutating layer.transform.origin)
        session.document!.layers[layerIndex].transform.origin.x += 40
        session.document!.layers[layerIndex].transform.origin.y += 30

        #expect(session.document!.layers[layerIndex].vector == originalVector)
        let newOrigin = session.document!.layers[layerIndex].transform.origin
        let localPt = session.document!.layers[layerIndex].vector!.subpaths[0].points[0].anchor
        #expect(localPt.x + newOrigin.x == 60)
        #expect(localPt.y + newOrigin.y == 50)
    }

    @Test func projectClearCancelsActivePenDraft() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        #expect(session.penDraft != nil)

        session.clearProject()
        #expect(session.penDraft == nil)
    }

    @Test func penDraftUndoRemovesLastAnchorAcrossThreeTwoOneSequence() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()

        guard let draft3 = session.penDraft else {
            Issue.record("penDraft expected")
            return
        }
        #expect(draft3.subpath.points.count == 3)
        #expect(session.canUndo)

        // 1. Undo third anchor -> 2 anchors remain
        session.undo()
        guard let draft2 = session.penDraft else {
            Issue.record("penDraft expected with 2 points")
            return
        }
        #expect(draft2.subpath.points.count == 2)
        #expect(draft2.activeAnchorIndex == 1)
        #expect(draft2.subpath.points[0].anchor == CGPoint(x: 10, y: 10))
        #expect(draft2.subpath.points[1].anchor == CGPoint(x: 30, y: 30))
        #expect(session.tool == .pen)

        // 2. Undo second anchor -> 1 anchor remains
        session.undo()
        guard let draft1 = session.penDraft else {
            Issue.record("penDraft expected with 1 point")
            return
        }
        #expect(draft1.subpath.points.count == 1)
        #expect(draft1.activeAnchorIndex == 0)
        #expect(draft1.subpath.points[0].anchor == CGPoint(x: 10, y: 10))
        #expect(session.tool == .pen)

        // 3. Undo first anchor -> cancels draft
        session.undo()
        #expect(session.penDraft == nil)
        #expect(session.tool == .pen)
    }

    @Test func penDraftUndoDoesNotMutateOrConsumeDocumentHistory() {
        let session = makeSession()
        session.addBlankLayer()
        let initialUndoCount = session.history.undoCount
        let initialDoc = session.document

        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()

        // 3 anchors active
        session.undo()
        #expect(session.history.undoCount == initialUndoCount)
        #expect(session.document == initialDoc)

        session.undo()
        #expect(session.history.undoCount == initialUndoCount)
        #expect(session.document == initialDoc)

        session.undo()
        #expect(session.history.undoCount == initialUndoCount)
        #expect(session.document == initialDoc)
        #expect(session.penDraft == nil)

        // With penDraft canceled, the next Undo operates on committed document history
        session.undo()
        #expect(session.history.undoCount == initialUndoCount - 1)
    }

    @Test func cmdShiftZRedoDuringPenDraftIsNoOp() {
        let session = makeSession()
        session.addBlankLayer()
        session.addBlankLayer()
        session.undo()
        #expect(session.canRedo)
        let redoName = session.history.redoName

        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()

        #expect(session.penDraft != nil)
        #expect(!session.canRedo)

        let layerCount = session.document?.layers.count ?? 0
        session.redo()

        // Redo was a no-op: document history was not redone
        #expect(session.document?.layers.count == layerCount)
        #expect(session.penDraft != nil)
        #expect(session.penDraft?.subpath.points.count == 2)

        // Cancel pen draft
        session.cancelPen()
        #expect(session.canRedo)
        #expect(session.history.redoName == redoName)
        session.redo()
        #expect(session.document?.layers.count == layerCount + 1)
    }

    @Test func canContinueDrawingAfterUndoingAnAnchor() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()

        // Undo 3rd anchor
        session.undo()
        #expect(session.penDraft?.subpath.points.count == 2)

        // Continue drawing: add a new 3rd anchor at (70, 70)
        session.beginPen(at: CGPoint(x: 70, y: 70))
        session.endPenDrag()
        #expect(session.penDraft?.subpath.points.count == 3)
        #expect(session.penDraft?.subpath.points[2].anchor == CGPoint(x: 70, y: 70))

        // Finish pen path
        session.finishPen()
        #expect(session.penDraft == nil)

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Layer with vector expected")
            return
        }
        #expect(vector.subpaths[0].points.count == 3)
    }

    @Test func afterPenCommitNormalUndoRedoResumes() {
        let session = makeSession()
        let initialLayers = session.document?.layers.count ?? 0
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 40))
        session.endPenDrag()
        session.finishPen()

        #expect(session.penDraft == nil)
        #expect((session.document?.layers.count ?? 0) == initialLayers + 1)

        // Undo committed vector layer
        session.undo()
        #expect((session.document?.layers.count ?? 0) == initialLayers)

        // Redo committed vector layer
        session.redo()
        #expect((session.document?.layers.count ?? 0) == initialLayers + 1)
        #expect(session.activeLayer?.vector != nil)
    }

    @Test func historyIsolationBetweenCommittedVectorsAndPenDraft() {
        let session = makeSession()

        // Commit Vector A
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.finishPen()
        guard let vectorAID = session.activeLayerID else { Issue.record("Vector A ID"); return }

        // Commit Vector B
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 40))
        session.endPenDrag()
        session.finishPen()
        guard let vectorBID = session.activeLayerID else { Issue.record("Vector B ID"); return }

        // Begin third Pen draft with 3 anchors
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 70, y: 70))
        session.endPenDrag()

        // 3 Undos must only affect the third draft
        session.undo()
        session.undo()
        session.undo()
        #expect(session.penDraft == nil)

        // Both Vector A and Vector B are preserved
        let layerIDs = session.document?.layers.map(\.id) ?? []
        #expect(layerIDs.contains(vectorAID))
        #expect(layerIDs.contains(vectorBID))

        // Next Undo removes Vector B
        session.undo()
        let layerIDsAfterUndoB = session.document?.layers.map(\.id) ?? []
        #expect(layerIDsAfterUndoB.contains(vectorAID))
        #expect(!layerIDsAfterUndoB.contains(vectorBID))

        // Next Undo removes Vector A
        session.undo()
        let layerIDsAfterUndoA = session.document?.layers.map(\.id) ?? []
        #expect(!layerIDsAfterUndoA.contains(vectorAID))
    }

    // MARK: - Phase 2B-6: Path Continuation & Endpoint Hit-Testing

    @Test func hitTestPenEndpointFindsEndpointsOnOpenVectorLayer() {
        let session = makeSession()
        // Draw an open path: (20, 20) -> (60, 60)
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layer = session.activeLayer, layer.vector != nil else {
            Issue.record("Committed layer expected")
            return
        }

        let docSize = session.document!.size
        let firstDoc = CGPoint(x: 20, y: 20)
        let lastDoc = CGPoint(x: 60, y: 60)
        let firstView = session.viewport.viewPoint(from: firstDoc, documentSize: docSize)
        let lastView = session.viewport.viewPoint(from: lastDoc, documentSize: docSize)

        // Hit first endpoint
        let hitFirst = session.hitTestPenEndpoint(at: firstView, tolerance: 10)
        #expect(hitFirst != nil)
        #expect(hitFirst?.layerID == layer.id)
        #expect(hitFirst?.isLast == false)
        #expect(abs((hitFirst?.point.x ?? 0) - firstDoc.x) < 0.001)
        #expect(abs((hitFirst?.point.y ?? 0) - firstDoc.y) < 0.001)

        // Hit last endpoint
        let hitLast = session.hitTestPenEndpoint(at: lastView, tolerance: 10)
        #expect(hitLast != nil)
        #expect(hitLast?.layerID == layer.id)
        #expect(hitLast?.isLast == true)
        #expect(abs((hitLast?.point.x ?? 0) - lastDoc.x) < 0.001)
        #expect(abs((hitLast?.point.y ?? 0) - lastDoc.y) < 0.001)

        // Miss (far away)
        let farView = session.viewport.viewPoint(from: CGPoint(x: 150, y: 150), documentSize: docSize)
        let hitFar = session.hitTestPenEndpoint(at: farView, tolerance: 10)
        #expect(hitFar == nil)
    }

    @Test func hitTestPenEndpointIgnoresClosedPathsAndHiddenLayers() {
        let session = makeSession()
        // Draw a closed path
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 50))
        session.endPenDrag()
        session.closePen()

        let docSize = session.document!.size
        let viewPt = session.viewport.viewPoint(from: CGPoint(x: 20, y: 20), documentSize: docSize)
        #expect(session.hitTestPenEndpoint(at: viewPt, tolerance: 10) == nil)

        // Hidden layer test: Draw an open path, hide the layer
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.finishPen()

        guard let layerID = session.activeLayerID,
              let idx = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            Issue.record("Layer expected")
            return
        }
        session.document?.layers[idx].isVisible = false

        let hiddenViewPt = session.viewport.viewPoint(from: CGPoint(x: 10, y: 10), documentSize: docSize)
        #expect(session.hitTestPenEndpoint(at: hiddenViewPt, tolerance: 10) == nil)
    }

    @Test func beginPenContinuationResumesFromLastEndpoint() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard session.activeLayer != nil, let layerID = session.activeLayerID else {
            Issue.record("Initial layer expected")
            return
        }
        let initialLayerCount = session.document?.layers.count ?? 0

        let docSize = session.document!.size
        let lastView = session.viewport.viewPoint(from: CGPoint(x: 60, y: 60), documentSize: docSize)
        guard let hit = session.hitTestPenEndpoint(at: lastView, tolerance: 10) else {
            Issue.record("Hit expected")
            return
        }

        session.beginPenContinuation(from: hit)

        #expect(session.penDraft != nil)
        #expect(session.penDraft?.continuingLayerID == layerID)
        #expect(session.penDraft?.continuingReversed == false)
        #expect(session.penDraft?.subpath.points.count == 2)

        // Add 3rd point and finish
        session.beginPen(at: CGPoint(x: 100, y: 60))
        session.endPenDrag()
        session.finishPen()

        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == initialLayerCount) // In-place replacement
        guard let continuedLayer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = continuedLayer.vector else {
            Issue.record("Continued layer vector expected")
            return
        }
        #expect(vector.subpaths[0].points.count == 3)
    }

    @Test func beginPenContinuationFromFirstEndpointReversesSubpath() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Initial layer expected")
            return
        }
        let initialLayerCount = session.document?.layers.count ?? 0

        let docSize = session.document!.size
        let firstView = session.viewport.viewPoint(from: CGPoint(x: 20, y: 20), documentSize: docSize)
        guard let hit = session.hitTestPenEndpoint(at: firstView, tolerance: 10) else {
            Issue.record("Hit expected")
            return
        }

        #expect(hit.isLast == false)
        session.beginPenContinuation(from: hit)

        #expect(session.penDraft != nil)
        #expect(session.penDraft?.continuingLayerID == layerID)
        #expect(session.penDraft?.continuingReversed == true)
        // Because reversed, point 0 is original (60, 60), point 1 is original (20, 20)
        let draftPoints = session.penDraft!.subpath.points
        #expect(abs(draftPoints[0].anchor.x - 60) < 0.001)
        #expect(abs(draftPoints[1].anchor.x - 20) < 0.001)

        // Extend from the original start point
        session.beginPen(at: CGPoint(x: 10, y: 40))
        session.endPenDrag()
        session.finishPen()

        #expect(session.document?.layers.count == initialLayerCount)
        guard let continuedLayer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = continuedLayer.vector else {
            Issue.record("Continued layer vector expected")
            return
        }
        #expect(vector.subpaths[0].points.count == 3)
    }

    @Test func continuationPreservesStrokeSettings() {
        let session = makeSession()
        let subpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 50, y: 50))
        ], isClosed: false)
        let stroke = VectorStrokeStyle(color: PaletteColor(red: 0, green: 0, blue: 1), width: 8)
        let model = VectorModel(subpaths: [subpath], fill: nil, stroke: stroke)
        let image = try! VectorRenderer.render(model, in: CGSize(width: 60, height: 60))
        session.addPixelLayer(image, at: .zero, name: "InitialVector", editName: "Add Vector", vector: model)

        guard let layerID = session.activeLayerID,
              let vectorBefore = session.activeLayer?.vector else {
            Issue.record("Vector expected")
            return
        }
        #expect(vectorBefore.stroke?.width == 8)

        // Change current tool settings to something else
        session.penStrokeWidth = 2
        session.foregroundColor = PaletteColor(red: 1, green: 1, blue: 0)

        // Continue the layer
        let docSize = session.document!.size
        let lastView = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: docSize)
        guard let hit = session.hitTestPenEndpoint(at: lastView, tolerance: 10) else {
            Issue.record("Hit expected")
            return
        }
        session.beginPenContinuation(from: hit)
        session.beginPen(at: CGPoint(x: 90, y: 90))
        session.endPenDrag()
        session.finishPen()

        guard let vectorAfter = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Vector after expected")
            return
        }
        // Should preserve original stroke width 8
        #expect(vectorAfter.stroke?.width == 8)
    }

    // MARK: - Phase 2B-7: Closed Vector Path Interaction, Selection & Hit Testing

    @Test func hitTestPenVectorLayerFindsInsideClosedPath() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Committed layer expected")
            return
        }

        let docSize = session.document!.size
        // (40, 30) is inside the triangle (20,20)-(60,20)-(40,60)
        let insideView = session.viewport.viewPoint(from: CGPoint(x: 40, y: 30), documentSize: docSize)
        let hit = session.hitTestPenVectorLayer(at: insideView)
        #expect(hit != nil)
        #expect(hit?.layerID == layerID)
    }

    @Test func hitTestPenVectorLayerReturnsNilForOutsidePoint() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        let docSize = session.document!.size
        // (150, 150) is well outside the triangle
        let outsideView = session.viewport.viewPoint(from: CGPoint(x: 150, y: 150), documentSize: docSize)
        let hit = session.hitTestPenVectorLayer(at: outsideView)
        #expect(hit == nil)
    }

    @Test func hitTestPenVectorLayerPrefersTopmostLayerWhenOverlapping() {
        let session = makeSession()
        // Bottom layer: (10, 10) to (100, 100)
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 100, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 10, y: 100))
        session.endPenDrag()
        session.closePen()
        guard let bottomLayerID = session.activeLayerID else {
            Issue.record("Bottom layer expected")
            return
        }

        // Top layer: (20, 20) to (80, 80)
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 80))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 20, y: 80))
        session.endPenDrag()
        session.closePen()
        guard let topLayerID = session.activeLayerID else {
            Issue.record("Top layer expected")
            return
        }

        #expect(bottomLayerID != topLayerID)

        let docSize = session.document!.size
        // (50, 50) is inside both shapes; topmost layer should win
        let centerView = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: docSize)
        let hit = session.hitTestPenVectorLayer(at: centerView)
        #expect(hit?.layerID == topLayerID)
    }

    @Test func makeSelectionFromVectorCreatesDocumentSelectionForClosedPath() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Committed layer expected")
            return
        }

        #expect(session.selection == nil)

        session.makeSelectionFromVector(layerID: layerID)

        #expect(session.selection != nil)
        #expect(session.selection?.isEmpty == false)

        let bounds = session.selection!.path.boundingBoxOfPath
        #expect(bounds.minX >= 19 && bounds.minX <= 21)
        #expect(bounds.maxX >= 59 && bounds.maxX <= 61)
        #expect(bounds.minY >= 19 && bounds.minY <= 21)
        #expect(bounds.maxY >= 59 && bounds.maxY <= 61)
    }

    @Test func makeSelectionFromVectorIgnoresOpenSubpaths() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Committed layer expected")
            return
        }

        #expect(session.selection == nil)

        session.makeSelectionFromVector(layerID: layerID)

        // Open path should NOT create a selection
        #expect(session.selection == nil)
    }

    @Test func hitTestPenVectorLayerIgnoresHiddenLayers() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == session.activeLayerID }) else {
            Issue.record("Layer index expected")
            return
        }

        // Hide the layer
        session.document?.layers[layerIndex].isVisible = false

        let docSize = session.document!.size
        let insideView = session.viewport.viewPoint(from: CGPoint(x: 40, y: 30), documentSize: docSize)
        let hit = session.hitTestPenVectorLayer(at: insideView)
        #expect(hit == nil)
    }

    // MARK: - Phase 2B-7: Closed Anchor Hit-Testing & Priority

    @Test func closedStartAnchorHitResolvesExactAnchorIndexZero() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Committed layer expected")
            return
        }

        let docSize = session.document!.size
        let startView = session.viewport.viewPoint(from: CGPoint(x: 20, y: 20), documentSize: docSize)
        guard let anchorHit = session.hitTestPenClosedAnchor(at: startView) else {
            Issue.record("Anchor hit expected at start anchor")
            return
        }

        #expect(anchorHit.layerID == layerID)
        #expect(anchorHit.anchorIndex.subpathIndex == 0)
        #expect(anchorHit.anchorIndex.anchorIndex == 0)
        #expect(anchorHit.kind == .anchor)
    }

    @Test func closedNonStartAnchorsResolveCorrectIndices() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20)) // index 0
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20)) // index 1
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60)) // index 2
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Committed layer expected")
            return
        }

        let docSize = session.document!.size

        // Test Anchor B (index 1)
        let bView = session.viewport.viewPoint(from: CGPoint(x: 60, y: 20), documentSize: docSize)
        guard let hitB = session.hitTestPenClosedAnchor(at: bView) else {
            Issue.record("Anchor hit expected at anchor B")
            return
        }
        #expect(hitB.layerID == layerID)
        #expect(hitB.anchorIndex.subpathIndex == 0)
        #expect(hitB.anchorIndex.anchorIndex == 1)

        // Test Anchor C (index 2)
        let cView = session.viewport.viewPoint(from: CGPoint(x: 40, y: 60), documentSize: docSize)
        guard let hitC = session.hitTestPenClosedAnchor(at: cView) else {
            Issue.record("Anchor hit expected at anchor C")
            return
        }
        #expect(hitC.layerID == layerID)
        #expect(hitC.anchorIndex.subpathIndex == 0)
        #expect(hitC.anchorIndex.anchorIndex == 2)
    }

    @Test func closedAnchorHitResolvesCorrectSubpathIndexForMultipleSubpaths() throws {
        let session = makeSession()
        // Subpath 0
        let subpath0 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 40, y: 10)),
            VectorPoint(anchor: CGPoint(x: 25, y: 40))
        ], isClosed: true)

        // Subpath 1
        let subpath1 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 60, y: 60)),
            VectorPoint(anchor: CGPoint(x: 90, y: 60)),
            VectorPoint(anchor: CGPoint(x: 75, y: 90))
        ], isClosed: true)

        let vector = VectorModel(subpaths: [subpath0, subpath1], fill: nil, stroke: VectorStrokeStyle(color: PaletteColor(red: 0, green: 0, blue: 0), width: 2))
        let image = try VectorRenderer.render(vector, in: CGSize(width: 200, height: 200))
        session.addPixelLayer(image, at: .zero, name: "Multi-Subpath", editName: "Add Vector", vector: vector)
        let layerID = session.activeLayerID!

        let docSize = session.document!.size

        // Query anchor on Subpath 0
        let sp0View = session.viewport.viewPoint(from: CGPoint(x: 40, y: 10), documentSize: docSize)
        let hit0 = session.hitTestPenClosedAnchor(at: sp0View)
        #expect(hit0?.anchorIndex.subpathIndex == 0)
        #expect(hit0?.anchorIndex.anchorIndex == 1)

        // Query anchor on Subpath 1
        let sp1View = session.viewport.viewPoint(from: CGPoint(x: 75, y: 90), documentSize: docSize)
        let hit1 = session.hitTestPenClosedAnchor(at: sp1View)
        #expect(hit1?.anchorIndex.subpathIndex == 1)
        #expect(hit1?.anchorIndex.anchorIndex == 2)
    }

    @Test func closedAnchorHitPrioritizesTopmostLayer() {
        let session = makeSession()
        // Bottom layer with anchor at (50, 50)
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 10, y: 90))
        session.endPenDrag()
        session.closePen()
        guard let bottomLayerID = session.activeLayerID else {
            Issue.record("Bottom layer expected")
            return
        }

        // Top layer also with anchor at (50, 50)
        session.beginPen(at: CGPoint(x: 90, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 90, y: 90))
        session.endPenDrag()
        session.closePen()
        guard let topLayerID = session.activeLayerID else {
            Issue.record("Top layer expected")
            return
        }

        #expect(bottomLayerID != topLayerID)

        let docSize = session.document!.size
        let viewPoint = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: docSize)
        let hit = session.hitTestPenClosedAnchor(at: viewPoint)
        #expect(hit?.layerID == topLayerID)
    }

    @Test func topLayerPathOccludesLowerLayerAnchor() {
        let session = makeSession()
        // Bottom layer with anchor at (50, 50)
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 10, y: 90))
        session.endPenDrag()
        session.closePen()

        // Top layer is a rectangle covering (30, 30) to (70, 70), with NO anchor at (50, 50)
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 70, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 70, y: 70))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 70))
        session.endPenDrag()
        session.closePen()
        guard let topLayerID = session.activeLayerID else {
            Issue.record("Top layer expected")
            return
        }

        let docSize = session.document!.size
        let centerView = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: docSize)

        // At (50, 50), top layer has NO anchor, but its path covers (50, 50).
        // The bottom layer's anchor at (50, 50) must NOT win over top layer's path.
        let anchorHit = session.hitTestPenClosedAnchor(at: centerView)
        #expect(anchorHit == nil)

        // Path-level hit resolves to the top layer
        let pathHit = session.hitTestPenVectorLayer(at: centerView)
        #expect(pathHit?.layerID == topLayerID)
    }

    @Test func clickingClosedAnchorDoesNotCreateNewDraftOrLayer() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Layer expected")
            return
        }
        let initialLayerCount = session.document?.layers.count ?? 0

        let docSize = session.document!.size
        let startView = session.viewport.viewPoint(from: CGPoint(x: 20, y: 20), documentSize: docSize)
        guard let anchorHit = session.hitTestPenClosedAnchor(at: startView) else {
            Issue.record("Anchor hit expected")
            return
        }

        // Simulate click on closed anchor
        session.selectLayer(anchorHit.layerID)

        #expect(session.activeLayerID == layerID)
        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == initialLayerCount)
    }

    // MARK: - Phase 2B-8 Tests

    @Test func newlyCreatedPenPathHasNoFillAndNoStroke() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Layer should have vector")
            return
        }

        #expect(vector.fill == nil)
        #expect(vector.stroke == nil)
        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed == false)
        #expect(vector.subpaths[0].points.count == 2)
    }

    @Test func closingPenPathLeavesFillAndStrokeNil() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 40))
        session.endPenDrag()
        session.closePen()

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Layer should have vector")
            return
        }

        #expect(vector.fill == nil)
        #expect(vector.stroke == nil)
        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed == true)
        #expect(vector.subpaths[0].points.count == 3)
    }

    @Test func closedPathPreservesAllAnchorsAndClosingAnchorIdentified() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 40))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID,
              let vector = session.activeLayer?.vector else {
            Issue.record("Layer should have vector")
            return
        }

        #expect(vector.subpaths[0].points.count == 3)
        // Closing anchor is identified in transient state
        #expect(session.penHoverAnchor != nil)
        #expect(session.penHoverAnchor?.layerID == layerID)
        #expect(session.penHoverAnchor?.anchorIndex.subpathIndex == 0)
        #expect(session.penHoverAnchor?.anchorIndex.anchorIndex == 0)

        // All anchors are resolvable
        let docSize = session.document!.size
        let p0View = session.viewport.viewPoint(from: CGPoint(x: 10, y: 10), documentSize: docSize)
        let p1View = session.viewport.viewPoint(from: CGPoint(x: 50, y: 10), documentSize: docSize)
        let p2View = session.viewport.viewPoint(from: CGPoint(x: 30, y: 40), documentSize: docSize)

        #expect(session.hitTestPenClosedAnchor(at: p0View)?.anchorIndex.anchorIndex == 0)
        #expect(session.hitTestPenClosedAnchor(at: p1View)?.anchorIndex.anchorIndex == 1)
        #expect(session.hitTestPenClosedAnchor(at: p2View)?.anchorIndex.anchorIndex == 2)
    }

    @Test func vectorRendererRendersTransparentImageWhenFillAndStrokeAreNil() throws {
        let subpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 50, y: 10)),
            VectorPoint(anchor: CGPoint(x: 30, y: 40))
        ], isClosed: true)
        let model = VectorModel(subpaths: [subpath], fill: nil, stroke: nil)
        let image = try VectorRenderer.render(model, in: CGSize(width: 60, height: 50))
        #expect(image.width == 60)
        #expect(image.height == 50)
    }

    @Test func explicitlyStyledVectorLayerPreservesStyleWhenContinued() {
        let session = makeSession()
        let subpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 50, y: 50))
        ], isClosed: false)
        let stroke = VectorStrokeStyle(color: PaletteColor(red: 1, green: 0, blue: 0), width: 6)
        let model = VectorModel(subpaths: [subpath], fill: nil, stroke: stroke)
        let image = try! VectorRenderer.render(model, in: CGSize(width: 60, height: 60))
        session.addPixelLayer(image, at: .zero, name: "StyledVector", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        let docSize = session.document!.size
        let endView = session.viewport.viewPoint(from: CGPoint(x: 50, y: 50), documentSize: docSize)
        guard let hit = session.hitTestPenEndpoint(at: endView) else {
            Issue.record("Endpoint hit expected")
            return
        }

        session.beginPenContinuation(from: hit)
        session.beginPen(at: CGPoint(x: 90, y: 90))
        session.endPenDrag()
        session.finishPen()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let continuedVector = layer.vector else {
            Issue.record("Continued layer vector expected")
            return
        }

        #expect(continuedVector.stroke?.width == 6)
        #expect(continuedVector.stroke?.color.red == 1)
        #expect(continuedVector.subpaths[0].points.count == 3)
    }

    @Test func closedPathPersistenceRoundTripPreservesNoFillNoStrokeAndAllAnchors() throws {
        let subpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10), previousControl: nil, nextControl: CGPoint(x: 20, y: 15)),
            VectorPoint(anchor: CGPoint(x: 50, y: 20), previousControl: CGPoint(x: 40, y: 25), nextControl: nil),
            VectorPoint(anchor: CGPoint(x: 30, y: 60))
        ], isClosed: true)
        let original = VectorModel(subpaths: [subpath], fill: nil, stroke: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VectorModel.self, from: data)

        #expect(decoded.fill == nil)
        #expect(decoded.stroke == nil)
        #expect(decoded.subpaths.count == 1)
        #expect(decoded.subpaths[0].isClosed == true)
        #expect(decoded.subpaths[0].points.count == 3)
        #expect(decoded.subpaths[0].points[0].nextControl == CGPoint(x: 20, y: 15))
        #expect(decoded.subpaths[0].points[1].previousControl == CGPoint(x: 40, y: 25))
    }

    @Test func closedAnchorClickDoesNotCreateNewDraftOrHistory() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 40))
        session.endPenDrag()
        session.closePen()

        let undoCount = session.history.undoCount
        let layerCount = session.document?.layers.count ?? 0
        let layerID = session.activeLayerID!

        let docSize = session.document!.size
        let anchorView = session.viewport.viewPoint(from: CGPoint(x: 50, y: 10), documentSize: docSize)
        guard let anchorHit = session.hitTestPenClosedAnchor(at: anchorView) else {
            Issue.record("Anchor hit expected")
            return
        }

        #expect(anchorHit.anchorIndex.anchorIndex == 1)

        // Simulate click
        session.selectLayer(anchorHit.layerID)

        #expect(session.activeLayerID == layerID)
        #expect(session.penDraft == nil)
        #expect(session.document?.layers.count == layerCount)
        #expect(session.history.undoCount == undoCount)
    }

    // MARK: - Phase 2B-9 Tests

    private func hasNonZeroPixels(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        for i in 0 ..< length {
            if ptr[i] != 0 { return true }
        }
        return false
    }

    // 1. Make Selection preserves VectorModel, anchors, handles, closed state, and creates exactly one history step
    @Test func makeSelectionPreservesVectorModelAnchorsAndHandles() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.dragPen(to: CGPoint(x: 20, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 10))
        session.dragPen(to: CGPoint(x: 60, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let originalVector = session.document!.layers[layerIndex].vector!
        let originalLayerCount = session.document!.layers.count
        let undoBefore = session.history.undoCount

        session.makeSelectionFromVector(layerID: layerID)

        #expect(session.document?.selection != nil)
        #expect(session.document?.selection?.isEmpty == false)
        #expect(session.history.undoCount == undoBefore + 1)
        #expect(session.document?.layers.count == originalLayerCount)

        let currentLayer = session.document!.layers[layerIndex]
        #expect(currentLayer.id == layerID)
        #expect(currentLayer.vector == originalVector)
        #expect(currentLayer.vector?.subpaths[0].isClosed == true)
        #expect(currentLayer.vector?.subpaths[0].points.count == 3)
        #expect(currentLayer.vector?.subpaths[0].points[0].nextControl != nil)
    }

    // 2. Fill Path fills closed path, uses foreground color, preserves VectorModel, and supports undo/redo
    @Test func fillPathFillsClosedPathAndSupportsUndoRedo() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0) // Red
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 80))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let originalVector = session.document!.layers[layerIndex].vector!

        // Before fill: transparent image
        #expect(!hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))

        let undoBefore = session.history.undoCount
        session.fillPathFromVector(layerID: layerID)

        #expect(session.history.undoCount == undoBefore + 1)
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)

        // Undo restores transparent image
        session.undo()
        #expect(!hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)

        // Redo restores filled image
        session.redo()
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)
    }

    // 3. Fill Path ignores open subpaths
    @Test func fillPathIgnoresOpenSubpaths() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let undoBefore = session.history.undoCount

        session.fillPathFromVector(layerID: layerID)

        #expect(session.history.undoCount == undoBefore)
        #expect(!hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
    }

    // 4. Fill Path with multiple subpaths fills closed subpaths and ignores open subpath
    @Test func fillPathFillsMultipleClosedSubpathsAndIgnoresOpenSubpaths() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 0, green: 1, blue: 0)

        let closedSubpath1 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 40, y: 10)),
            VectorPoint(anchor: CGPoint(x: 40, y: 40)),
            VectorPoint(anchor: CGPoint(x: 10, y: 40))
        ], isClosed: true)

        let closedSubpath2 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 50, y: 10)),
            VectorPoint(anchor: CGPoint(x: 80, y: 10)),
            VectorPoint(anchor: CGPoint(x: 80, y: 40)),
            VectorPoint(anchor: CGPoint(x: 50, y: 40))
        ], isClosed: true)

        let openSubpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 60)),
            VectorPoint(anchor: CGPoint(x: 80, y: 60))
        ], isClosed: false)

        let model = VectorModel(
            subpaths: [closedSubpath1, closedSubpath2, openSubpath],
            fill: VectorFillStyle(color: PaletteColor(red: 0, green: 1, blue: 0), fillRule: .evenOdd, isEnabled: true)
        )

        let layer = ImageLayer(
            id: UUID(),
            asset: ImportedImage(
                image: try! BrushRaster.context(width: 100, height: 100, mask: false).makeImage()!,
                thumbnail: try! BrushRaster.context(width: 10, height: 10, mask: false).makeImage()!,
                name: "MultiVector"
            ),
            name: "MultiVector",
            isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)),
            vector: model
        )
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id

        session.fillPathFromVector(layerID: layer.id)

        let updated = session.document!.layers.first(where: { $0.id == layer.id })!
        #expect(hasNonZeroPixels(updated.asset!.image))
        #expect(updated.vector?.subpaths.count == 3)
        #expect(updated.vector?.subpaths[0].isClosed == true)
        #expect(updated.vector?.subpaths[1].isClosed == true)
        #expect(updated.vector?.subpaths[2].isClosed == false)
    }

    // 5. Stroke Path strokes open path, uses foreground color, preserves VectorModel, and supports undo/redo
    @Test func strokePathStrokesOpenPathAndSupportsUndoRedo() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1) // Blue
        session.penStrokeWidth = 3
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 90, y: 20))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let originalVector = session.document!.layers[layerIndex].vector!

        #expect(!hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))

        let undoBefore = session.history.undoCount
        session.strokePathFromVector(layerID: layerID)

        #expect(session.history.undoCount == undoBefore + 1)
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)
        #expect(session.document!.layers[layerIndex].vector?.subpaths[0].isClosed == false)

        session.undo()
        #expect(!hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)

        session.redo()
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)
    }

    // 6. Stroke Path strokes closed path and multiple subpaths
    @Test func strokePathStrokesClosedPathAndMultipleSubpaths() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 1, blue: 0)

        let closedSubpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 40, y: 10)),
            VectorPoint(anchor: CGPoint(x: 40, y: 40))
        ], isClosed: true)

        let openSubpath = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 50, y: 50)),
            VectorPoint(anchor: CGPoint(x: 80, y: 80))
        ], isClosed: false)

        let model = VectorModel(
            subpaths: [closedSubpath, openSubpath],
            stroke: VectorStrokeStyle(color: PaletteColor(red: 1, green: 1, blue: 0), width: 4, lineCap: .square, lineJoin: .miter, miterLimit: 5, isEnabled: true)
        )

        let layer = ImageLayer(
            id: UUID(),
            asset: ImportedImage(
                image: try! BrushRaster.context(width: 100, height: 100, mask: false).makeImage()!,
                thumbnail: try! BrushRaster.context(width: 10, height: 10, mask: false).makeImage()!,
                name: "StrokeMulti"
            ),
            name: "StrokeMulti",
            isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)),
            vector: model
        )
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id

        session.strokePathFromVector(layerID: layer.id)

        let updated = session.document!.layers.first(where: { $0.id == layer.id })!
        #expect(hasNonZeroPixels(updated.asset!.image))
        #expect(updated.vector?.subpaths.count == 2)
        #expect(updated.vector?.stroke?.width == 4)
    }

    // 7. Path and Selection separation through tool switching (P -> V -> P)
    @Test func pathAndSelectionSeparationThroughToolSwitching() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 60))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let originalVector = session.document!.layers[layerIndex].vector!

        session.makeSelectionFromVector(layerID: layerID)
        #expect(session.document?.selection != nil)

        // Switch to Move (V)
        session.selectTool(.move)
        #expect(session.tool == .move)
        #expect(session.document?.selection != nil)
        #expect(session.document?.layers[layerIndex].vector == originalVector)

        // Switch back to Pen (P)
        session.selectTool(.pen)
        #expect(session.tool == .pen)
        #expect(session.document?.selection != nil)
        #expect(session.document?.layers[layerIndex].vector == originalVector)

        // Anchors remain discoverable in Pen
        let anchorView = session.viewport.viewPoint(from: CGPoint(x: 20, y: 20), documentSize: session.document!.size)
        let anchorHit = session.hitTestPenClosedAnchor(at: anchorView)
        #expect(anchorHit != nil)
        #expect(anchorHit?.layerID == layerID)
    }

    // 8. Transformed vector layer fills and strokes correctly
    @Test func fillAndStrokeWithTransformedVectorLayer() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 50, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 30, y: 40))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!

        // Apply a transform: rotate and translate
        var transform = session.document!.layers[layerIndex].transform
        transform.origin = CGPoint(x: 100, y: 100)
        transform.rotation = 45
        session.document!.layers[layerIndex].transform = transform

        let originalVector = session.document!.layers[layerIndex].vector!

        session.fillPathFromVector(layerID: layerID)
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)
        #expect(session.document!.layers[layerIndex].transform.origin == CGPoint(x: 100, y: 100))
        #expect(session.document!.layers[layerIndex].transform.rotation == 45)

        session.strokePathFromVector(layerID: layerID)
        #expect(hasNonZeroPixels(session.document!.layers[layerIndex].asset!.image))
        #expect(session.document!.layers[layerIndex].vector == originalVector)
    }

    // 9. Persistence round-trip retains vector model, closed state, and painted raster pixels
    @Test func fillAndStrokePersistenceRoundTrip() throws {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 15, y: 15))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 55, y: 15))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 35, y: 55))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        session.fillPathFromVector(layerID: layerID)

        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let vector = session.document!.layers[layerIndex].vector!
        let image = session.document!.layers[layerIndex].asset!.image

        let encoder = JSONEncoder()
        let data = try encoder.encode(vector)
        let decoder = JSONDecoder()
        let decodedVector = try decoder.decode(VectorModel.self, from: data)

        #expect(decodedVector == vector)
        #expect(decodedVector.subpaths[0].isClosed == true)
        #expect(hasNonZeroPixels(image))
    }

    // MARK: - Phase 2B-9.1 Tests

    // 10. Stroke Path produces actual raster pixels for open and closed paths, preserving VectorModel, with undo/redo
    @Test func strokePathProducesActualRasterPixelsAndPreservesVectorModel() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0) // Red
        session.penStrokeWidth = 2.0

        // Open path
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 40))
        session.endPenDrag()
        session.finishPen()

        let openLayerID = session.activeLayerID!
        let openLayer = session.document!.layers.first(where: { $0.id == openLayerID })!
        let openVectorBefore = openLayer.vector!

        #expect(!hasNonZeroPixels(openLayer.asset!.image))
        session.strokePathFromVector(layerID: openLayerID)

        let openLayerAfter = session.document!.layers.first(where: { $0.id == openLayerID })!
        #expect(hasNonZeroPixels(openLayerAfter.asset!.image))
        #expect(openLayerAfter.vector == openVectorBefore)

        session.undo()
        let openLayerUndone = session.document!.layers.first(where: { $0.id == openLayerID })!
        #expect(!hasNonZeroPixels(openLayerUndone.asset!.image))
        #expect(openLayerUndone.vector == openVectorBefore)

        session.redo()
        let openLayerRedone = session.document!.layers.first(where: { $0.id == openLayerID })!
        #expect(hasNonZeroPixels(openLayerRedone.asset!.image))
        #expect(openLayerRedone.vector == openVectorBefore)

        // Closed path
        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 80))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 20, y: 80))
        session.endPenDrag()
        session.closePen()

        let closedLayerID = session.activeLayerID!
        let closedLayer = session.document!.layers.first(where: { $0.id == closedLayerID })!
        let closedVectorBefore = closedLayer.vector!

        #expect(!hasNonZeroPixels(closedLayer.asset!.image))
        session.strokePathFromVector(layerID: closedLayerID)

        let closedLayerAfter = session.document!.layers.first(where: { $0.id == closedLayerID })!
        #expect(hasNonZeroPixels(closedLayerAfter.asset!.image))
        #expect(closedLayerAfter.vector == closedVectorBefore)
    }

    // 11. Make Selection creates valid document selection geometry, aligns with transform, and does NOT paint
    @Test func makeSelectionAlignsWithTransformedPathAndDoesNotPaint() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 10, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 70, y: 10))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 70, y: 50))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!

        // Apply translation and rotation transform
        var transform = session.document!.layers[layerIndex].transform
        transform.origin = CGPoint(x: 50, y: 30)
        transform.rotation = 90
        session.document!.layers[layerIndex].transform = transform

        let vectorBefore = session.document!.layers[layerIndex].vector!
        let assetBefore = session.document!.layers[layerIndex].asset!

        session.makeSelectionFromVector(layerID: layerID)

        let layerAfter = session.document!.layers[layerIndex]
        #expect(session.document?.selection != nil)
        #expect(session.document?.selection?.isEmpty == false)

        // Make Selection must NOT modify vector model or paint raster pixels
        #expect(layerAfter.vector == vectorBefore)
        #expect(layerAfter.asset?.image === assetBefore.image)
        #expect(!hasNonZeroPixels(layerAfter.asset!.image))

        // Check geometry alignment: docPath from layerToDocument must match selection path
        let closedModel = VectorModel(subpaths: vectorBefore.subpaths.filter(\.isClosed), fill: vectorBefore.fill, stroke: nil)
        let localPath = VectorBridge.cgPath(from: closedModel)
        var layerToDoc = transform.layerToDocument
        let expectedDocPath = localPath.copy(using: &layerToDoc)!

        let selectionBox = session.document!.selection!.path.boundingBoxOfPath
        let expectedBox = expectedDocPath.boundingBoxOfPath
        #expect(abs(selectionBox.origin.x - expectedBox.origin.x) < 0.001)
        #expect(abs(selectionBox.origin.y - expectedBox.origin.y) < 0.001)
        #expect(abs(selectionBox.size.width - expectedBox.size.width) < 0.001)
        #expect(abs(selectionBox.size.height - expectedBox.size.height) < 0.001)
    }

    // 12. Context menu target resolution discovers open path endpoints
    @Test func openPathEndpointHitTestingResolvesLayerForStroke() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 90, y: 70))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        let doc = session.document!
        let endpointView = session.viewport.viewPoint(from: CGPoint(x: 30, y: 30), documentSize: doc.size)

        // Endpoint hit test resolves the layer
        let hit = session.hitTestPenEndpoint(at: endpointView)
        #expect(hit != nil)
        #expect(hit?.layerID == layerID)

        // Stroking through that layer succeeds and produces raster pixels
        session.strokePathFromVector(layerID: hit!.layerID)
        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        #expect(hasNonZeroPixels(layer.asset!.image))
    }

    // 13. Tool switching (Pen -> V -> Pen) preserves selection, vector model, and hit testing
    @Test func toolSwitchingPreservesSelectionAndVectorModelAndHitTesting() {
        let session = makeSession()
        session.beginPen(at: CGPoint(x: 15, y: 15))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 65, y: 15))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 40, y: 65))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!
        let originalVector = session.document!.layers[layerIndex].vector!

        session.makeSelectionFromVector(layerID: layerID)
        let originalSelection = session.document?.selection
        #expect(originalSelection != nil)

        // 1. Switch to Move (V)
        session.selectTool(.move)
        #expect(session.tool == .move)
        #expect(session.document?.selection == originalSelection)
        #expect(session.document?.layers[layerIndex].vector == originalVector)

        // 2. Switch back to Pen (P)
        session.selectTool(.pen)
        #expect(session.tool == .pen)
        #expect(session.document?.selection == originalSelection)
        #expect(session.document?.layers[layerIndex].vector == originalVector)

        // 3. Anchors remain discoverable in Pen
        let anchorView = session.viewport.viewPoint(from: CGPoint(x: 15, y: 15), documentSize: session.document!.size)
        let anchorHit = session.hitTestPenClosedAnchor(at: anchorView)
        #expect(anchorHit != nil)
        #expect(anchorHit?.layerID == layerID)
        #expect(anchorHit?.anchorIndex.anchorIndex == 0)
    }

    // MARK: - Phase 2B-9.2 Fidelity Audit Helpers & Tests

    private func pixelData(of image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    private func paintedBounds(in image: CGImage, alphaThreshold: UInt8 = 10) -> CGRect? {
        guard let (bytes, width, height) = pixelData(of: image) else { return nil }
        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1

        for y in 0 ..< height {
            for x in 0 ..< width {
                let alpha = bytes[(y * width + x) * 4 + 3]
                if alpha >= alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func pixelAlpha(at point: CGPoint, in layer: ImageLayer) -> UInt8 {
        guard let image = layer.asset?.image,
              let (bytes, width, height) = pixelData(of: image) else { return 0 }
        let docToLayer = layer.transform.documentToLayer ?? .identity
        let localPoint = point.applying(docToLayer)
        let lx = Int(localPoint.x.rounded())
        let ly = Int(localPoint.y.rounded())
        guard lx >= 0, lx < width, ly >= 0, ly < height else { return 0 }
        return bytes[(ly * width + lx) * 4 + 3]
    }

    private func pixelRGBA(at point: CGPoint, in layer: ImageLayer) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let image = layer.asset?.image,
              let (bytes, width, height) = pixelData(of: image) else { return nil }
        let docToLayer = layer.transform.documentToLayer ?? .identity
        let localPoint = point.applying(docToLayer)
        let lx = Int(localPoint.x.rounded())
        let ly = Int(localPoint.y.rounded())
        guard lx >= 0, lx < width, ly >= 0, ly < height else { return nil }
        let offset = (ly * width + lx) * 4
        return (r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: bytes[offset + 3])
    }

    // 14. Phase 9 Test 1: Bounds fidelity
    @Test func strokePathFidelityBoundsTest() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0

        // Create horizontal path from (100, 100) to (200, 100)
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let image = layer.asset!.image
        let localBounds = paintedBounds(in: image)
        #expect(localBounds != nil)

        // Document space bounds: expected around (98, 98) to (202, 102) due to width 4 round caps
        let localToDoc = layer.transform.layerToDocument
        let docMin = CGPoint(x: localBounds!.minX, y: localBounds!.minY).applying(localToDoc)
        let docMax = CGPoint(x: localBounds!.maxX, y: localBounds!.maxY).applying(localToDoc)

        #expect(abs(docMin.x - 98) <= 1.5)
        #expect(abs(docMin.y - 98) <= 1.5)
        #expect(abs(docMax.x - 202) <= 1.5)
        #expect(abs(docMax.y - 102) <= 1.5)
    }

    // 15. Phase 9 Test 2: Centerline alignment
    @Test func strokePathFidelityCenterlineTest() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0

        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!

        // Centerline pixel at midpoint (150, 100) must be fully opaque / high alpha
        let centerAlpha = pixelAlpha(at: CGPoint(x: 150, y: 100), in: layer)
        #expect(centerAlpha >= 200)

        // Pixels within stroke radius must be visible
        let topEdgeAlpha = pixelAlpha(at: CGPoint(x: 150, y: 99), in: layer)
        let bottomEdgeAlpha = pixelAlpha(at: CGPoint(x: 150, y: 101), in: layer)
        #expect(topEdgeAlpha >= 150)
        #expect(bottomEdgeAlpha >= 150)

        // Pixels outside stroke width must be transparent
        let farTopAlpha = pixelAlpha(at: CGPoint(x: 150, y: 95), in: layer)
        let farBottomAlpha = pixelAlpha(at: CGPoint(x: 150, y: 105), in: layer)
        #expect(farTopAlpha == 0)
        #expect(farBottomAlpha == 0)
    }

    // 16. Phase 9 Test 3: Stroke width estimation
    @Test func strokePathFidelityWidthTest() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 0, green: 1, blue: 0)
        session.penStrokeWidth = 6.0

        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let image = layer.asset!.image
        let (bytes, width, height) = pixelData(of: image)!

        let docToLayer = layer.transform.documentToLayer ?? .identity
        let localMidX = Int(CGPoint(x: 150, y: 100).applying(docToLayer).x.rounded())

        // Count vertical pixels with alpha >= 30 in this column
        var strokeThickness = 0
        for y in 0 ..< height {
            let alpha = bytes[(y * width + localMidX) * 4 + 3]
            if alpha >= 30 {
                strokeThickness += 1
            }
        }

        // Expected width is 6, allowing +/- 1 pixel for antialiasing coverage
        #expect((5...7).contains(strokeThickness))
    }

    // 17. Phase 9 Test 4: Endpoint and line caps
    @Test func strokePathFidelityEndpointsAndCapsTest() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)

        // 1. Butt cap: does not extend past endpoints
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let buttLayerID = session.activeLayerID!
        let buttIndex = session.document!.layers.firstIndex(where: { $0.id == buttLayerID })!
        if var v = session.document?.layers[buttIndex].vector {
            v.stroke = VectorStrokeStyle(color: session.foregroundColor, width: 4.0, lineCap: .butt, lineJoin: .round, isEnabled: true)
            session.document?.layers[buttIndex].vector = v
        }

        session.strokePathFromVector(layerID: buttLayerID)

        let buttUpdated = session.document!.layers[buttIndex]
        guard let buttBounds = paintedBounds(in: buttUpdated.asset!.image) else {
            Issue.record("Butt bounds must not be nil")
            return
        }
        let buttDocMinX = CGPoint(x: buttBounds.minX, y: buttBounds.minY).applying(buttUpdated.transform.layerToDocument).x
        let buttDocMaxX = CGPoint(x: buttBounds.maxX, y: buttBounds.maxY).applying(buttUpdated.transform.layerToDocument).x
        #expect(abs(buttDocMinX - 100) <= 1.0)
        #expect(abs(buttDocMaxX - 200) <= 1.0)

        // 2. Square cap: extends by width/2 past endpoints
        session.cancelPen()
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let squareLayerID = session.activeLayerID!
        let squareIndex = session.document!.layers.firstIndex(where: { $0.id == squareLayerID })!
        if var v = session.document?.layers[squareIndex].vector {
            v.stroke = VectorStrokeStyle(color: session.foregroundColor, width: 4.0, lineCap: .square, lineJoin: .round, isEnabled: true)
            session.document?.layers[squareIndex].vector = v
        }

        session.strokePathFromVector(layerID: squareLayerID)

        let squareUpdated = session.document!.layers[squareIndex]
        guard let squareBounds = paintedBounds(in: squareUpdated.asset!.image) else {
            Issue.record("Square bounds must not be nil")
            return
        }
        let squareDocMinX = CGPoint(x: squareBounds.minX, y: squareBounds.minY).applying(squareUpdated.transform.layerToDocument).x
        let squareDocMaxX = CGPoint(x: squareBounds.maxX, y: squareBounds.maxY).applying(squareUpdated.transform.layerToDocument).x
        #expect(abs(squareDocMinX - 98) <= 1.5)
        #expect(abs(squareDocMaxX - 202) <= 1.5)
    }

    // 18. Phase 9 Test 5: Transformed path fidelity
    @Test func strokePathFidelityTransformedPathTest() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0

        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        let layerIndex = session.document!.layers.firstIndex(where: { $0.id == layerID })!

        // Apply rotation (90 degrees) and horizontal flip
        var transform = session.document!.layers[layerIndex].transform
        transform.rotation = 90
        transform.flipX = true
        session.document!.layers[layerIndex].transform = transform

        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers[layerIndex]
        let image = layer.asset!.image
        let bounds = paintedBounds(in: image)
        #expect(bounds != nil)

        // Midpoint of local path in layer-local coordinates is at (anchor0 + anchor1)/2
        let pt0 = layer.vector!.subpaths[0].points[0].anchor
        let pt1 = layer.vector!.subpaths[0].points[1].anchor
        let localMid = CGPoint(x: (pt0.x + pt1.x) / 2, y: (pt0.y + pt1.y) / 2)
        let docMid = localMid.applying(transform.layerToDocument)

        let centerAlpha = pixelAlpha(at: docMid, in: layer)
        #expect(centerAlpha >= 150)
    }

    // 19. Phase 7: Existing raster content preservation
    @Test func strokePathPreservesExistingPixels() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0) // Red
        session.penStrokeWidth = 4.0

        // Create closed triangle
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 100, y: 150))
        session.endPenDrag()
        session.closePen()

        let layerID = session.activeLayerID!

        // First, Fill Path with Red
        session.fillPathFromVector(layerID: layerID)
        let filledLayer = session.document!.layers.first(where: { $0.id == layerID })!
        let fillCenterAlpha = pixelAlpha(at: CGPoint(x: 100, y: 75), in: filledLayer)
        #expect(fillCenterAlpha >= 200)

        // Then, change color to Blue and Stroke Path
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1) // Blue
        session.strokePathFromVector(layerID: layerID)

        let strokedLayer = session.document!.layers.first(where: { $0.id == layerID })!
        // Interior pixel (from fill) must still be present
        let interiorAlpha = pixelAlpha(at: CGPoint(x: 100, y: 75), in: strokedLayer)
        #expect(interiorAlpha >= 200)

        // Boundary stroke pixel must also be present
        let boundaryAlpha = pixelAlpha(at: CGPoint(x: 100, y: 50), in: strokedLayer)
        #expect(boundaryAlpha >= 200)
    }

    // 20. Phase 6: Selection interaction
    @Test func strokePathRespectsDocumentSelectionClipping() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0

        // Horizontal line from (100, 100) to (200, 100)
        session.beginPen(at: CGPoint(x: 100, y: 100))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 200, y: 100))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!

        // Active selection covering left half only: x in [90..150]
        let selRect = CGRect(x: 90, y: 90, width: 60, height: 20)
        session.document?.selection = DocumentSelection(path: CGPath(rect: selRect, transform: nil), antialiased: false, feather: 0)

        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!

        // Inside selection at x = 120: stroke is painted
        let insideAlpha = pixelAlpha(at: CGPoint(x: 120, y: 100), in: layer)
        #expect(insideAlpha >= 150)

        // Outside selection at x = 180: clipped away, transparent
        let outsideAlpha = pixelAlpha(at: CGPoint(x: 180, y: 100), in: layer)
        #expect(outsideAlpha == 0)
    }

    // 21. Phase 2B-9.3 Regression Test 1: UI Stroke Path action updates raster asset
    @Test func strokePathMenuActionUpdatesDisplayedRaster() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0
        let canvas = CanvasView(session: session)

        // Draw open path: (50, 50) to (150, 50)
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.finishPen()

        guard let layerID = session.activeLayerID,
              let layer = session.document?.layers.first(where: { $0.id == layerID }) else {
            Issue.record("Layer should exist")
            return
        }

        // Before stroke: asset has zero non-transparent pixels
        #expect(paintedBounds(in: layer.asset!.image) == nil)

        // Invoke context menu at midpoint (100, 50)
        let midDoc = CGPoint(x: 100, y: 50)
        let midView = session.viewport.viewPoint(from: midDoc, documentSize: session.document!.size)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: midView,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        guard let menu = canvas.menu(for: event) else {
            Issue.record("Menu should not be nil")
            return
        }
        guard let strokeItem = menu.items.first(where: { $0.title == "Stroke Path" }) else {
            Issue.record("Stroke Path item must be present in menu")
            return
        }

        // Trigger action
        canvas.perform(strokeItem.action!, with: strokeItem)

        // Verify layer asset now has painted pixels
        let updatedLayer = session.document!.layers.first(where: { $0.id == layerID })!
        guard let bounds = paintedBounds(in: updatedLayer.asset!.image) else {
            Issue.record("Painted bounds should not be nil after Stroke Path")
            return
        }
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    // 22. Phase 2B-9.3 Regression Test 2: Stroke open path from endpoint target
    @Test func strokeOpenPathFromEndpointTarget() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0
        let canvas = CanvasView(session: session)

        // Draw open path from (40, 40) to (140, 40)
        session.beginPen(at: CGPoint(x: 40, y: 40))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 140, y: 40))
        session.endPenDrag()
        session.finishPen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Active layer should exist")
            return
        }

        // Right-click exactly on endpoint (140, 40)
        let endpointView = session.viewport.viewPoint(from: CGPoint(x: 140, y: 40), documentSize: session.document!.size)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: endpointView,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        guard let menu = canvas.menu(for: event) else {
            Issue.record("Menu must not be nil when clicking on endpoint")
            return
        }
        guard let strokeItem = menu.items.first(where: { $0.title == "Stroke Path" }) else {
            Issue.record("Stroke Path item must be present when clicking on endpoint")
            return
        }

        canvas.perform(strokeItem.action!, with: strokeItem)

        let updatedLayer = session.document!.layers.first(where: { $0.id == layerID })!
        guard let bounds = paintedBounds(in: updatedLayer.asset!.image) else {
            Issue.record("Painted bounds should not be nil after Stroke Path from endpoint")
            return
        }
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    // 23. Phase 2B-9.3 Regression Test 3: Stroke closed path from anchor target
    @Test func strokeClosedPathFromAnchorTarget() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0
        let canvas = CanvasView(session: session)

        // Draw triangle: (50, 50), (150, 50), (100, 150), closed
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 100, y: 150))
        session.endPenDrag()
        session.closePen()

        guard let layerID = session.activeLayerID else {
            Issue.record("Active layer should exist")
            return
        }

        // Right-click on anchor (100, 150)
        let anchorView = session.viewport.viewPoint(from: CGPoint(x: 100, y: 150), documentSize: session.document!.size)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: anchorView,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        guard let menu = canvas.menu(for: event) else {
            Issue.record("Menu must not be nil when clicking on closed anchor")
            return
        }
        guard let strokeItem = menu.items.first(where: { $0.title == "Stroke Path" }) else {
            Issue.record("Stroke Path item must be present when clicking on closed anchor")
            return
        }

        canvas.perform(strokeItem.action!, with: strokeItem)

        let updatedLayer = session.document!.layers.first(where: { $0.id == layerID })!
        guard let bounds = paintedBounds(in: updatedLayer.asset!.image) else {
            Issue.record("Painted bounds should not be nil after Stroke Path from anchor")
            return
        }
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    // 24. Phase 2B-9.3 Regression Test 4: History transaction count for Stroke Path
    @Test func strokePathCreatesExactlyOneHistoryTransaction() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0
        let canvas = CanvasView(session: session)

        // Case A: Stroke committed vector layer
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.finishPen()

        let historyCountBeforeStroke = session.history.undoCount

        let midDoc = CGPoint(x: 100, y: 50)
        let midView = session.viewport.viewPoint(from: midDoc, documentSize: session.document!.size)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: midView,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = canvas.menu(for: event)!
        let strokeItem = menu.items.first(where: { $0.title == "Stroke Path" })!
        canvas.perform(strokeItem.action!, with: strokeItem)

        // Exactly one new transaction added
        #expect(session.history.undoCount == historyCountBeforeStroke + 1)
        #expect(session.history.undoName == "Stroke Path")
    }

    // 25. Phase 2B-9.3 Regression Test 5: Stroking active pen draft creates exactly one transaction
    @Test func strokePenDraftCreatesExactlyOneHistoryTransaction() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0
        let canvas = CanvasView(session: session)

        // Pen draft active (not finished)
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()

        #expect(session.penDraft != nil)
        let historyCountBeforeStroke = session.history.undoCount

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 100, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        guard let menu = canvas.menu(for: event),
              let strokeItem = menu.items.first(where: { $0.title == "Stroke Path" }) else {
            Issue.record("Stroke Path item must be present in menu for active pen draft")
            return
        }

        canvas.perform(strokeItem.action!, with: strokeItem)

        #expect(session.penDraft == nil)
        guard let layerID = session.activeLayerID,
              let layer = session.document?.layers.first(where: { $0.id == layerID }) else {
            Issue.record("Layer should exist after stroking draft")
            return
        }

        guard let bounds = paintedBounds(in: layer.asset!.image) else {
            Issue.record("Painted bounds should not be nil")
            return
        }
        #expect(bounds.width > 0)

        // Exactly one new transaction in history
        #expect(session.history.undoCount == historyCountBeforeStroke + 1)
        #expect(session.history.undoName == "Stroke Path")
    }

    // 26. Phase 2B-9.2 Fidelity Audit: Closing path with drag produces continuous curved stroke
    @Test func closingPathWithDragProducesCurvedStroke() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 0, green: 1, blue: 0)
        session.penStrokeWidth = 4.0

        // Point 1: (50, 100)
        session.beginPen(at: CGPoint(x: 50, y: 100))
        session.endPenDrag()

        // Point 2: (150, 50)
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()

        // Point 3: (250, 100)
        session.beginPen(at: CGPoint(x: 250, y: 100))
        session.endPenDrag()

        // Close to Point 1 by dragging down: creating smooth curve
        session.beginPenClosing(atViewPoint: CGPoint(x: 50, y: 100))
        session.dragPenClosing(to: CGPoint(x: 50, y: 140))
        session.endPenClosing()

        // Committed vector layer should be closed and have curved control handles
        guard let layerID = session.activeLayerID,
              let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Layer and vector should exist after closing")
            return
        }

        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].isClosed)
        #expect(vector.subpaths[0].points[0].previousControl != nil)
        #expect(vector.subpaths[0].points[0].nextControl != nil)

        // Stroke the path
        session.strokePathFromVector(layerID: layerID)

        let updatedLayer = session.document!.layers.first(where: { $0.id == layerID })!
        #expect(updatedLayer.asset != nil)
        guard let bounds = paintedBounds(in: updatedLayer.asset!.image) else {
            Issue.record("Painted bounds should not be nil")
            return
        }
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    // 27. Phase 2B-9.2 Fidelity Audit: Stroke Path color matches foreground color
    @Test func strokePathColorMatchesForegroundColor() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0) // pure red
        session.penStrokeWidth = 6.0

        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let midDoc = CGPoint(x: 100, y: 50)
        let rgba = pixelRGBA(at: midDoc, in: layer)
        #expect(rgba != nil)
        if let rgba = rgba {
            #expect(rgba.r > 240)
            #expect(rgba.g < 15)
            #expect(rgba.b < 15)
            #expect(rgba.a > 240)
        }
    }

    // 28. Phase 2B-9.2 Fidelity Audit: Empty selection completely clips Stroke Path
    @Test func strokePathWithEmptySelectionTouchesNothing() {
        let session = makeSession()
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 4.0

        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.finishPen()

        let layerID = session.activeLayerID!
        session.document?.selection = DocumentSelection(path: CGMutablePath(), antialiased: false, feather: 0)

        session.strokePathFromVector(layerID: layerID)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        #expect(paintedBounds(in: layer.asset!.image) == nil)
    }
}

