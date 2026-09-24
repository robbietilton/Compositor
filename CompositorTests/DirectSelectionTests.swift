import AppKit
import Testing
@testable import Compositor

@MainActor
@Suite(.serialized)
struct DirectSelectionTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 300, height: 300, emptyLayer: true)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.penStrokeWidth = 2
        return session
    }

    private func createTriangleLayer(in session: EditorSession) -> UUID {
        session.selectTool(.pen)
        session.beginPen(at: CGPoint(x: 50, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 150, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 100, y: 150))
        session.endPenDrag()
        session.closePen()
        return session.activeLayerID!
    }

    private func createCurvedLayer(in session: EditorSession) -> UUID {
        session.selectTool(.pen)
        session.beginPen(at: CGPoint(x: 40, y: 40))
        session.dragPen(to: CGPoint(x: 60, y: 50))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 120, y: 40))
        session.dragPen(to: CGPoint(x: 140, y: 30))
        session.endPenDrag()
        session.finishPen()
        return session.activeLayerID!
    }

    // 1. Direct Selection activates correctly
    @Test func directSelectionToolActivation() {
        let session = makeSession()
        session.selectTool(.directSelection)

        #expect(session.tool == .directSelection)
        #expect(session.vectorSelection == nil)
        #expect(session.directSelectionDrag == nil)
    }

    // 2. Clicking a vector anchor selects it
    @Test func clickingVectorAnchorSelectsIt() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Layer with vector expected")
            return
        }

        // Anchor 0 is at document point (50, 50)
        let anchor0Doc = vector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)
        let viewPoint = session.viewport.viewPoint(from: anchor0Doc, documentSize: session.document!.size)

        let hit = session.hitTestVectorAnchor(at: viewPoint)
        #expect(hit != nil)
        #expect(hit?.layerID == layerID)
        #expect(hit?.anchor == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))

        session.beginDirectSelectionDrag(at: anchor0Doc, clickedAnchor: hit!.anchor, in: layerID, toggle: false)
        #expect(session.vectorSelection?.selectedAnchors == [VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)])
    }

    // 3. Clicking a non-anchor does not mutate the vector model
    @Test func clickingNonAnchorDoesNotMutateVectorModel() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let vectorBefore = session.document?.layers.first(where: { $0.id == layerID })?.vector

        // Far away point from any anchor
        let nonAnchorView = CGPoint(x: 280, y: 280)
        let hit = session.hitTestVectorAnchor(at: nonAnchorView)
        #expect(hit == nil)

        session.deselectVectorAnchors()
        let vectorAfter = session.document?.layers.first(where: { $0.id == layerID })?.vector
        #expect(vectorBefore == vectorAfter)
    }

    // 4. Selected anchor is represented in transient selection state
    @Test func selectedAnchorRepresentedInTransientState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let anchorIdx = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(anchorIdx, in: layerID, toggle: false)

        #expect(session.vectorSelection?.layerID == layerID)
        #expect(session.vectorSelection?.selectedAnchors.contains(anchorIdx) == true)
        #expect(session.vectorSelection?.selectedAnchors.count == 1)
    }

    // 5. Moving one anchor changes only that anchor
    @Test func movingOneAnchorChangesOnlyThatAnchor() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let p0Init = initialVector.subpaths[0].points[0].anchor
        let p1Init = initialVector.subpaths[0].points[1].anchor
        let p2Init = initialVector.subpaths[0].points[2].anchor

        let anchor0Doc = p0Init.applying(layer.transform.layerToDocument)
        let anchorIdx = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)

        session.beginDirectSelectionDrag(at: anchor0Doc, clickedAnchor: anchorIdx, in: layerID, toggle: false)
        let dragTargetDoc = CGPoint(x: anchor0Doc.x + 25, y: anchor0Doc.y + 15)
        session.dragDirectSelection(to: dragTargetDoc)
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Updated vector expected")
            return
        }

        let p0New = updatedVector.subpaths[0].points[0].anchor
        let p1New = updatedVector.subpaths[0].points[1].anchor
        let p2New = updatedVector.subpaths[0].points[2].anchor

        #expect(p0New.x == p0Init.x + 25)
        #expect(p0New.y == p0Init.y + 15)
        #expect(p1New == p1Init)
        #expect(p2New == p2Init)
    }

    // 6. Moving multiple selected anchors preserves their relative positions
    @Test func movingMultipleSelectedAnchorsPreservesRelativePositions() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let p0Init = initialVector.subpaths[0].points[0].anchor
        let p1Init = initialVector.subpaths[0].points[1].anchor
        let p2Init = initialVector.subpaths[0].points[2].anchor

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)

        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        session.selectVectorAnchor(a1, in: layerID, toggle: true)
        #expect(session.vectorSelection?.selectedAnchors.count == 2)

        let anchor0Doc = p0Init.applying(layer.transform.layerToDocument)
        session.beginDirectSelectionDrag(at: anchor0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: anchor0Doc.x + 30, y: anchor0Doc.y - 10))
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Updated vector expected")
            return
        }

        let p0New = updatedVector.subpaths[0].points[0].anchor
        let p1New = updatedVector.subpaths[0].points[1].anchor
        let p2New = updatedVector.subpaths[0].points[2].anchor

        #expect(p0New.x == p0Init.x + 30)
        #expect(p0New.y == p0Init.y - 10)
        #expect(p1New.x == p1Init.x + 30)
        #expect(p1New.y == p1Init.y - 10)
        #expect(p2New == p2Init)

        // Relative distance between p0 and p1 must remain exactly unchanged
        let initialDistance = hypot(p1Init.x - p0Init.x, p1Init.y - p0Init.y)
        let newDistance = hypot(p1New.x - p0New.x, p1New.y - p0New.y)
        #expect(abs(newDistance - initialDistance) < 0.001)
    }

    // 7. Unselected anchors remain unchanged
    @Test func unselectedAnchorsRemainUnchanged() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a2 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 2)
        session.selectVectorAnchor(a2, in: layerID, toggle: false)

        let a2Doc = initialVector.subpaths[0].points[2].anchor.applying(layer.transform.layerToDocument)
        session.beginDirectSelectionDrag(at: a2Doc, clickedAnchor: a2, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a2Doc.x + 10, y: a2Doc.y + 20))
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Vector expected")
            return
        }

        #expect(updatedVector.subpaths[0].points[0] == initialVector.subpaths[0].points[0])
        #expect(updatedVector.subpaths[0].points[1] == initialVector.subpaths[0].points[1])
    }

    // 8. Existing Bézier handles are preserved
    @Test func existingBezierHandlesPreserved() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let pt0Init = initialVector.subpaths[0].points[0]
        #expect(pt0Init.nextControl != nil)
        #expect(pt0Init.previousControl != nil)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = pt0Init.anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 15, y: a0Doc.y - 12))
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Vector expected")
            return
        }

        let pt0New = updatedVector.subpaths[0].points[0]
        #expect(pt0New.nextControl != nil)
        #expect(pt0New.previousControl != nil)

        #expect(pt0New.anchor.x == pt0Init.anchor.x + 15)
        #expect(pt0New.anchor.y == pt0Init.anchor.y - 12)
        #expect(pt0New.nextControl?.x == pt0Init.nextControl!.x + 15)
        #expect(pt0New.nextControl?.y == pt0Init.nextControl!.y - 12)
        #expect(pt0New.previousControl?.x == pt0Init.previousControl!.x + 15)
        #expect(pt0New.previousControl?.y == pt0Init.previousControl!.y - 12)

        // Vector delta between anchor and controls must remain completely identical
        #expect(pt0New.nextControl!.x - pt0New.anchor.x == pt0Init.nextControl!.x - pt0Init.anchor.x)
        #expect(pt0New.nextControl!.y - pt0New.anchor.y == pt0Init.nextControl!.y - pt0Init.anchor.y)
    }

    // 9. Layer transform remains unchanged while editing anchors
    @Test func layerTransformRemainsUnchangedWhileEditingAnchors() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            Issue.record("Layer index expected")
            return
        }

        let initialTransform = session.document!.layers[layerIndex].transform

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = session.document!.layers[layerIndex].vector!.subpaths[0].points[0].anchor.applying(initialTransform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 40, y: a0Doc.y + 40))
        session.endDirectSelectionDrag()

        let currentTransform = session.document!.layers[layerIndex].transform
        #expect(currentTransform.origin == initialTransform.origin)
        #expect(currentTransform.size == initialTransform.size)
        #expect(currentTransform.rotation == initialTransform.rotation)
        #expect(currentTransform.flipX == initialTransform.flipX)
        #expect(currentTransform.flipY == initialTransform.flipY)
    }

    // 10. Zoom does not corrupt logical coordinates
    @Test func zoomDoesNotCorruptLogicalCoordinates() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        // Test at 200% zoom
        session.zoom(to: 2.0)
        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 20, y: a0Doc.y + 10))
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Vector expected")
            return
        }

        let p0New = updatedVector.subpaths[0].points[0].anchor
        #expect(p0New.x == initialVector.subpaths[0].points[0].anchor.x + 20)
        #expect(p0New.y == initialVector.subpaths[0].points[0].anchor.y + 10)
    }

    // 11. Drag creates exactly one history operation
    @Test func dragCreatesExactlyOneHistoryOperation() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)

        // 100 drag events
        for step in 1...100 {
            session.dragDirectSelection(to: CGPoint(x: a0Doc.x + CGFloat(step), y: a0Doc.y + CGFloat(step)))
        }

        session.endDirectSelectionDrag()

        #expect(session.history.undoCount == initialHistoryCount + 1)
    }

    // 12. Undo restores complete pre-drag vector state
    @Test func undoRestoresCompletePreDragVectorState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 35, y: a0Doc.y + 25))
        session.endDirectSelectionDrag()

        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector != initialVector)

        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)
    }

    // 13. Redo restores complete post-drag vector state
    @Test func redoRestoresCompletePostDragVectorState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 35, y: a0Doc.y + 25))
        session.endDirectSelectionDrag()

        let modifiedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector

        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)

        session.redo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == modifiedVector)
    }

    // 14. Escape during drag restores exact pre-drag state
    @Test func escapeDuringDragRestoresExactPreDragState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 50, y: a0Doc.y + 50))

        #expect(session.directSelectionDrag != nil)
        session.cancelDirectSelectionDrag()

        #expect(session.directSelectionDrag == nil)
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)
    }

    // 15. Escape during drag creates no history entry
    @Test func escapeDuringDragCreatesNoHistoryEntry() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: a0Doc.x + 50, y: a0Doc.y + 50))
        session.cancelDirectSelectionDrag()

        #expect(session.history.undoCount == initialHistoryCount)
    }

    // 16. Escape while not dragging clears anchor selection
    @Test func escapeWhileNotDraggingClearsAnchorSelection() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        #expect(session.vectorSelection != nil)

        session.deselectVectorAnchors()
        #expect(session.vectorSelection == nil)
        #expect(session.document?.layers.count == 2)
    }

    // 17. Shift-click adds and toggles anchor selection
    @Test func shiftClickAddsAndTogglesAnchorSelection() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)

        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        #expect(session.vectorSelection?.selectedAnchors == [a0])

        // Shift-click a1 adds it
        session.selectVectorAnchor(a1, in: layerID, toggle: true)
        #expect(session.vectorSelection?.selectedAnchors == [a0, a1])

        // Shift-click a0 toggles it off
        session.selectVectorAnchor(a0, in: layerID, toggle: true)
        #expect(session.vectorSelection?.selectedAnchors == [a1])
    }

    // 18. Clicking anchor without dragging creates no document-history mutation
    @Test func clickingAnchorWithoutDraggingCreatesNoDocumentHistory() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a0Doc = initialVector.subpaths[0].points[0].anchor.applying(layer.transform.layerToDocument)

        session.beginDirectSelectionDrag(at: a0Doc, clickedAnchor: a0, in: layerID, toggle: false)
        session.endDirectSelectionDrag() // No drag movement

        #expect(session.history.undoCount == initialHistoryCount)
    }

    // 19. Switching away from Direct Selection clears transient state
    @Test func switchingAwayFromDirectSelectionClearsTransientState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        #expect(session.vectorSelection != nil)

        session.selectTool(.move)
        #expect(session.tool == .move)
        #expect(session.vectorSelection == nil)
        #expect(session.directSelectionDrag == nil)
    }

    // 20. Existing PenTool behavior remains unchanged
    @Test func existingPenToolBehaviorRemainsUnchanged() {
        let session = makeSession()
        session.selectTool(.pen)

        session.beginPen(at: CGPoint(x: 20, y: 20))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()
        session.finishPen()

        guard let layer = session.activeLayer, let vector = layer.vector else {
            Issue.record("Committed layer expected")
            return
        }

        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].points.count == 2)
        #expect(layer.asset != nil)
    }

    // 21. Existing next handle can be selected
    @Test func existingNextHandleCanBeSelected() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let nextControlLocal = vector.subpaths[0].points[0].nextControl!
        let nextDoc = nextControlLocal.applying(layer.transform.layerToDocument)
        let nextView = session.viewport.viewPoint(from: nextDoc, documentSize: session.document!.size)

        let hit = session.hitTestDirectSelection(at: nextView)
        #expect(hit != nil)
        #expect(hit?.layerID == layerID)
        #expect(hit?.anchorIndex == a0)
        #expect(hit?.kind == .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: hit!, side: .next)
        #expect(session.vectorSelection?.selectedHandle == SelectedHandle(anchorIndex: a0, side: .next))
        #expect(session.vectorSelection?.selectedAnchors.contains(a0) == true)
        #expect(session.directSelectionDrag != nil)
    }

    // 22. Existing previous handle can be selected
    @Test func existingPreviousHandleCanBeSelected() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let prevControlLocal = vector.subpaths[0].points[0].previousControl!
        let prevDoc = prevControlLocal.applying(layer.transform.layerToDocument)
        let prevView = session.viewport.viewPoint(from: prevDoc, documentSize: session.document!.size)

        let hit = session.hitTestDirectSelection(at: prevView)
        #expect(hit != nil)
        #expect(hit?.layerID == layerID)
        #expect(hit?.anchorIndex == a0)
        #expect(hit?.kind == .handle(.previous))

        session.beginDirectSelectionHandleDrag(at: prevDoc, target: hit!, side: .previous)
        #expect(session.vectorSelection?.selectedHandle == SelectedHandle(anchorIndex: a0, side: .previous))
    }

    // 23. Handle hit-testing is screen-space based
    @Test func handleHitTestingIsScreenSpaceBased() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let nextDoc = vector.subpaths[0].points[0].nextControl!.applying(layer.transform.layerToDocument)

        // At 100% zoom:
        let view100 = session.viewport.viewPoint(from: nextDoc, documentSize: session.document!.size)
        let nearView100 = CGPoint(x: view100.x + 6, y: view100.y)
        #expect(session.hitTestDirectSelection(at: nearView100, hitRadius: 10.0)?.kind == .handle(.next))
        let farView100 = CGPoint(x: view100.x + 15, y: view100.y)
        #expect(session.hitTestDirectSelection(at: farView100, hitRadius: 10.0) == nil)

        // At 200% zoom:
        session.zoom(to: 2.0)
        let view200 = session.viewport.viewPoint(from: nextDoc, documentSize: session.document!.size)
        let nearView200 = CGPoint(x: view200.x + 6, y: view200.y)
        #expect(session.hitTestDirectSelection(at: nearView200, hitRadius: 10.0)?.kind == .handle(.next))
        let farView200 = CGPoint(x: view200.x + 15, y: view200.y)
        #expect(session.hitTestDirectSelection(at: farView200, hitRadius: 10.0) == nil)
    }

    // 24. Moving next handle changes only next handle
    @Test func movingNextHandleChangesOnlyNextHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let initPt0 = initialVector.subpaths[0].points[0]
        let nextDoc = initPt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        let dragTargetDoc = CGPoint(x: nextDoc.x + 20, y: nextDoc.y + 15)
        session.dragDirectSelection(to: dragTargetDoc)
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Updated vector expected")
            return
        }

        let updatedPt0 = updatedVector.subpaths[0].points[0]
        #expect(updatedPt0.nextControl?.x == initPt0.nextControl!.x + 20)
        #expect(updatedPt0.nextControl?.y == initPt0.nextControl!.y + 15)
        #expect(updatedPt0.anchor == initPt0.anchor)
        #expect(updatedPt0.previousControl == initPt0.previousControl)
    }

    // 25. Moving previous handle changes only previous handle
    @Test func movingPreviousHandleChangesOnlyPreviousHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let initPt0 = initialVector.subpaths[0].points[0]
        let prevDoc = initPt0.previousControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.previous))

        session.beginDirectSelectionHandleDrag(at: prevDoc, target: target, side: .previous)
        let dragTargetDoc = CGPoint(x: prevDoc.x - 15, y: prevDoc.y + 25)
        session.dragDirectSelection(to: dragTargetDoc)
        session.endDirectSelectionDrag()

        guard let updatedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Updated vector expected")
            return
        }

        let updatedPt0 = updatedVector.subpaths[0].points[0]
        #expect(updatedPt0.previousControl?.x == initPt0.previousControl!.x - 15)
        #expect(updatedPt0.previousControl?.y == initPt0.previousControl!.y + 25)
        #expect(updatedPt0.anchor == initPt0.anchor)
        #expect(updatedPt0.nextControl == initPt0.nextControl)
    }

    // 26. Anchor remains unchanged while handle moves
    @Test func anchorRemainsUnchangedWhileHandleMoves() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let initPt0 = initialVector.subpaths[0].points[0]
        let nextDoc = initPt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 30, y: nextDoc.y - 40))
        session.endDirectSelectionDrag()

        let updatedPt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        #expect(updatedPt0.anchor == initPt0.anchor)
    }

    // 27. Opposite handle remains unchanged
    @Test func oppositeHandleRemainsUnchanged() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let initPt0 = initialVector.subpaths[0].points[0]
        let nextDoc = initPt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 50, y: nextDoc.y + 50))
        session.endDirectSelectionDrag()

        let updatedPt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        #expect(updatedPt0.previousControl == initPt0.previousControl)
    }

    // 28. Independent/asymmetric handles are preserved
    @Test func independentAsymmetricHandlesPreserved() {
        let session = makeSession()
        session.selectTool(.directSelection)

        let p0 = VectorPoint(
            anchor: CGPoint(x: 50, y: 50),
            previousControl: CGPoint(x: 30, y: 50),
            nextControl: CGPoint(x: 80, y: 70)
        )
        let p1 = VectorPoint(anchor: CGPoint(x: 150, y: 150))
        let model = VectorModel(
            subpaths: [VectorSubpath(points: [p0, p1], isClosed: false)],
            stroke: VectorStrokeStyle(color: PaletteColor(red: 0, green: 0, blue: 0), width: 2)
        )

        let layerID = session.activeLayerID!
        session.document?.layers[0].vector = model
        session.redrawVector(at: 0)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let nextDoc = p0.nextControl!.applying(session.document!.layers[0].transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 10, y: nextDoc.y - 20))
        session.endDirectSelectionDrag()

        let updatedPt = session.document!.layers[0].vector!.subpaths[0].points[0]
        #expect(updatedPt.previousControl == CGPoint(x: 30, y: 50))
        #expect(updatedPt.nextControl == CGPoint(x: 90, y: 50))
    }

    // 29. A point with only one handle remains valid after editing
    @Test func pointWithOnlyOneHandleRemainsValidAfterEditing() {
        let session = makeSession()
        session.selectTool(.directSelection)

        let p0 = VectorPoint(
            anchor: CGPoint(x: 50, y: 50),
            previousControl: nil,
            nextControl: CGPoint(x: 70, y: 60)
        )
        let p1 = VectorPoint(anchor: CGPoint(x: 120, y: 120))
        let model = VectorModel(
            subpaths: [VectorSubpath(points: [p0, p1], isClosed: false)],
            stroke: VectorStrokeStyle(color: PaletteColor(red: 0, green: 0, blue: 0), width: 2)
        )

        let layerID = session.activeLayerID!
        session.document?.layers[0].vector = model
        session.redrawVector(at: 0)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let nextDoc = p0.nextControl!.applying(session.document!.layers[0].transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 15, y: nextDoc.y + 10))
        session.endDirectSelectionDrag()

        let updatedPt = session.document!.layers[0].vector!.subpaths[0].points[0]
        #expect(updatedPt.isValid)
        #expect(updatedPt.previousControl == nil)
        #expect(updatedPt.nextControl == CGPoint(x: 85, y: 70))
    }

    // 30. Handle drag updates rendered geometry
    @Test func handleDragUpdatesRenderedGeometry() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            Issue.record("Layer index expected")
            return
        }

        let initialImage = session.document!.layers[layerIndex].asset?.image
        #expect(initialImage != nil)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers[layerIndex].vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(session.document!.layers[layerIndex].transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 40, y: nextDoc.y + 40))
        session.endDirectSelectionDrag()

        let updatedImage = session.document!.layers[layerIndex].asset?.image
        #expect(updatedImage != nil)
        #expect(updatedImage !== initialImage)
    }

    // 31. Handle drag does not modify LayerTransform
    @Test func handleDragDoesNotModifyLayerTransform() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            Issue.record("Layer index expected")
            return
        }

        let initialTransform = session.document!.layers[layerIndex].transform

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers[layerIndex].vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(initialTransform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 30, y: nextDoc.y - 20))
        session.endDirectSelectionDrag()

        let currentTransform = session.document!.layers[layerIndex].transform
        #expect(currentTransform.origin == initialTransform.origin)
        #expect(currentTransform.size == initialTransform.size)
        #expect(currentTransform.rotation == initialTransform.rotation)
        #expect(currentTransform.flipX == initialTransform.flipX)
        #expect(currentTransform.flipY == initialTransform.flipY)
    }

    // 32. Handle drag at different zoom levels preserves logical coordinates
    @Test func handleDragAtDifferentZoomLevelsPreservesLogicalCoordinates() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector expected")
            return
        }

        session.zoom(to: 2.0)
        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = initialVector.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 25, y: nextDoc.y + 15))
        session.endDirectSelectionDrag()

        let updatedPt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        #expect(updatedPt0.nextControl?.x == pt0.nextControl!.x + 25)
        #expect(updatedPt0.nextControl?.y == pt0.nextControl!.y + 15)
    }

    // 33. Handle drag creates exactly one history transaction
    @Test func handleDragCreatesExactlyOneHistoryTransaction() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        for step in 1...100 {
            session.dragDirectSelection(to: CGPoint(x: nextDoc.x + CGFloat(step), y: nextDoc.y + CGFloat(step)))
        }
        session.endDirectSelectionDrag()

        #expect(session.history.undoCount == initialHistoryCount + 1)
    }

    // 34. Undo restores exact pre-drag model
    @Test func undoRestoresExactPreDragModel() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = initialVector.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 30, y: nextDoc.y + 20))
        session.endDirectSelectionDrag()

        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector != initialVector)

        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)
    }

    // 35. Redo restores exact post-drag model
    @Test func redoRestoresExactPostDragModel() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = initialVector.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 30, y: nextDoc.y + 20))
        session.endDirectSelectionDrag()

        let modifiedVector = session.document?.layers.first(where: { $0.id == layerID })?.vector

        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)

        session.redo()
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == modifiedVector)
    }

    // 36. Escape during handle drag restores exact pre-drag model
    @Test func escapeDuringHandleDragRestoresExactPreDragModel() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let initialVector = layer.vector else {
            Issue.record("Curved vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = initialVector.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 40, y: nextDoc.y + 40))

        #expect(session.directSelectionDrag != nil)
        session.cancelDirectSelectionDrag()

        #expect(session.directSelectionDrag == nil)
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)
    }

    // 37. Escape during handle drag creates no history transaction
    @Test func escapeDuringHandleDragCreatesNoHistoryTransaction() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 40, y: nextDoc.y + 40))
        session.cancelDirectSelectionDrag()

        #expect(session.history.undoCount == initialHistoryCount)
    }

    // 38. Clicking a handle without moving it creates no history transaction
    @Test func clickingHandleWithoutMovingCreatesNoHistoryTransaction() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.endDirectSelectionDrag()

        #expect(session.history.undoCount == initialHistoryCount)
    }

    // 39. Existing vector persistence preserves handles
    @Test func existingVectorPersistencePreservesHandles() throws {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 25, y: nextDoc.y - 15))
        session.endDirectSelectionDrag()

        guard let originalVector = session.document?.layers.first(where: { $0.id == layerID })?.vector else {
            Issue.record("Vector expected")
            return
        }

        let data = try JSONEncoder().encode(originalVector)
        let decodedVector = try JSONDecoder().decode(VectorModel.self, from: data)

        #expect(decodedVector == originalVector)
        #expect(decodedVector.subpaths[0].points[0].nextControl == originalVector.subpaths[0].points[0].nextControl)
    }

    // 40. Section 4A: Hit target distinguishes anchor, previous-handle, and next-handle
    @Test func hitTargetDistinguishesAnchorPreviousAndNextHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Curved vector expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = vector.subpaths[0].points[0]
        let anchorView = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)
        let prevView = session.viewport.viewPoint(from: pt0.previousControl!.applying(layer.transform.layerToDocument), documentSize: session.document!.size)
        let nextView = session.viewport.viewPoint(from: pt0.nextControl!.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let hitAnchor = session.hitTestDirectSelection(at: anchorView)
        #expect(hitAnchor?.kind == .anchor)
        #expect(hitAnchor?.anchorIndex == a0)

        let hitPrev = session.hitTestDirectSelection(at: prevView)
        #expect(hitPrev?.kind == .handle(.previous))
        #expect(hitPrev?.anchorIndex == a0)

        let hitNext = session.hitTestDirectSelection(at: nextView)
        #expect(hitNext?.kind == .handle(.next))
        #expect(hitNext?.anchorIndex == a0)
    }

    // 41. Section 4A: Hit target distinguishes different subpaths and anchor indices
    @Test func hitTargetDistinguishesDifferentSubpathsAndAnchors() {
        let session = makeSession()
        session.selectTool(.directSelection)

        let p0 = VectorPoint(anchor: CGPoint(x: 20, y: 20))
        let p1 = VectorPoint(anchor: CGPoint(x: 60, y: 20))
        let subpath0 = VectorSubpath(points: [p0, p1], isClosed: false)

        let p2 = VectorPoint(anchor: CGPoint(x: 100, y: 100))
        let p3 = VectorPoint(anchor: CGPoint(x: 150, y: 100))
        let subpath1 = VectorSubpath(points: [p2, p3], isClosed: false)

        let model = VectorModel(
            subpaths: [subpath0, subpath1],
            stroke: VectorStrokeStyle(color: PaletteColor(red: 1, green: 0, blue: 0), width: 2)
        )
        session.document?.layers[0].vector = model
        session.redrawVector(at: 0)

        let layer = session.document!.layers[0]
        let viewP0 = session.viewport.viewPoint(from: p0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)
        let viewP1 = session.viewport.viewPoint(from: p1.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)
        let viewP2 = session.viewport.viewPoint(from: p2.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let hit0 = session.hitTestDirectSelection(at: viewP0)
        #expect(hit0?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))

        let hit1 = session.hitTestDirectSelection(at: viewP1)
        #expect(hit1?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1))

        let hit2 = session.hitTestDirectSelection(at: viewP2)
        #expect(hit2?.anchorIndex == VectorAnchorIndex(subpathIndex: 1, anchorIndex: 0))
    }

    // 42. Section 4A: Hit target distinguishes different vector layers
    @Test func hitTargetDistinguishesDifferentVectorLayers() {
        let session = makeSession()
        let layer1ID = createTriangleLayer(in: session)
        let layer2ID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let layer1 = session.document!.layers.first(where: { $0.id == layer1ID })!
        let layer2 = session.document!.layers.first(where: { $0.id == layer2ID })!

        let ptLayer1 = layer1.vector!.subpaths[0].points[0].anchor.applying(layer1.transform.layerToDocument)
        let ptLayer2 = layer2.vector!.subpaths[0].points[0].anchor.applying(layer2.transform.layerToDocument)

        let viewLayer1 = session.viewport.viewPoint(from: ptLayer1, documentSize: session.document!.size)
        let viewLayer2 = session.viewport.viewPoint(from: ptLayer2, documentSize: session.document!.size)

        let hit1 = session.hitTestDirectSelection(at: viewLayer1)
        #expect(hit1?.layerID == layer1ID)

        let hit2 = session.hitTestDirectSelection(at: viewLayer2)
        #expect(hit2?.layerID == layer2ID)
    }

    // 43. Section 4A: Hit target returns nil when outside hit tolerance
    @Test func hitTargetReturnsNilWhenOutsideTolerance() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let outsideView = CGPoint(x: 290, y: 290)
        #expect(session.hitTestDirectSelection(at: outsideView, hitRadius: 10.0) == nil)
    }

    // 44. Section 15: Handle drag on transformed layer preserves local coordinates
    @Test func handleDragOnTransformedLayerPreservesLocalCoordinates() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layerIndex = session.document?.layers.firstIndex(where: { $0.id == layerID }) else {
            Issue.record("Layer index expected")
            return
        }

        // Apply rotation and flip to layer transform
        session.document?.layers[layerIndex].transform.rotation = 90
        session.document?.layers[layerIndex].transform.flipX = true

        let layer = session.document!.layers[layerIndex]
        let initialVector = layer.vector!
        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let pt0 = initialVector.subpaths[0].points[0]
        let nextDoc = pt0.nextControl!.applying(layer.transform.layerToDocument)
        let target = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))

        session.beginDirectSelectionHandleDrag(at: nextDoc, target: target, side: .next)
        session.dragDirectSelection(to: CGPoint(x: nextDoc.x + 20, y: nextDoc.y + 30))
        session.endDirectSelectionDrag()

        let updatedLayer = session.document!.layers[layerIndex]
        #expect(updatedLayer.transform.rotation == 90)
        #expect(updatedLayer.transform.flipX == true)

        let updatedPt = updatedLayer.vector!.subpaths[0].points[0]
        #expect(updatedPt.nextControl != pt0.nextControl)
        #expect(updatedPt.anchor == pt0.anchor)
        #expect(updatedPt.previousControl == pt0.previousControl)
    }

    // 45. Section 13: DirectSelectionHitTarget identifies an anchor during secondary-click resolution
    @Test func contextualTargetIdentifiesAnchor() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let pt0 = vector.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(layer.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        let target = session.resolveDirectSelectionContextualTarget(at: viewPt)
        #expect(target != nil)
        #expect(target?.layerID == layerID)
        #expect(target?.anchorIndex == a0)
        #expect(target?.kind == .anchor)
        #expect(session.contextualHitTarget == target)
    }

    // 46. Section 13: DirectSelectionHitTarget identifies a previous handle
    @Test func contextualTargetIdentifiesPreviousHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let prevDoc = vector.subpaths[0].points[0].previousControl!.applying(layer.transform.layerToDocument)
        let prevView = session.viewport.viewPoint(from: prevDoc, documentSize: session.document!.size)

        let target = session.resolveDirectSelectionContextualTarget(at: prevView)
        #expect(target != nil)
        #expect(target?.layerID == layerID)
        #expect(target?.anchorIndex == a0)
        #expect(target?.kind == .handle(.previous))
        #expect(session.contextualHitTarget == target)
    }

    // 47. Section 13: DirectSelectionHitTarget identifies a next handle
    @Test func contextualTargetIdentifiesNextHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Curved vector layer expected")
            return
        }

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let nextDoc = vector.subpaths[0].points[0].nextControl!.applying(layer.transform.layerToDocument)
        let nextView = session.viewport.viewPoint(from: nextDoc, documentSize: session.document!.size)

        let target = session.resolveDirectSelectionContextualTarget(at: nextView)
        #expect(target != nil)
        #expect(target?.layerID == layerID)
        #expect(target?.anchorIndex == a0)
        #expect(target?.kind == .handle(.next))
        #expect(session.contextualHitTarget == target)
    }

    // 48. Section 13: DirectSelectionHitTarget identifies the correct layer
    @Test func contextualTargetIdentifiesCorrectLayer() {
        let session = makeSession()
        let layer1ID = createTriangleLayer(in: session)
        let layer2ID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let layer1 = session.document!.layers.first(where: { $0.id == layer1ID })!
        let layer2 = session.document!.layers.first(where: { $0.id == layer2ID })!

        let ptLayer1 = layer1.vector!.subpaths[0].points[0].anchor.applying(layer1.transform.layerToDocument)
        let ptLayer2 = layer2.vector!.subpaths[0].points[0].anchor.applying(layer2.transform.layerToDocument)

        let viewLayer1 = session.viewport.viewPoint(from: ptLayer1, documentSize: session.document!.size)
        let viewLayer2 = session.viewport.viewPoint(from: ptLayer2, documentSize: session.document!.size)

        let target1 = session.resolveDirectSelectionContextualTarget(at: viewLayer1)
        #expect(target1?.layerID == layer1ID)

        let target2 = session.resolveDirectSelectionContextualTarget(at: viewLayer2)
        #expect(target2?.layerID == layer2ID)
    }

    // 49. Section 13: DirectSelectionHitTarget identifies the correct subpath and anchor index
    @Test func contextualTargetIdentifiesCorrectSubpathAndIndex() {
        let session = makeSession()
        session.selectTool(.directSelection)

        let p0 = VectorPoint(anchor: CGPoint(x: 30, y: 30))
        let p1 = VectorPoint(anchor: CGPoint(x: 70, y: 30))
        let subpath0 = VectorSubpath(points: [p0, p1], isClosed: false)

        let p2 = VectorPoint(anchor: CGPoint(x: 110, y: 110))
        let p3 = VectorPoint(anchor: CGPoint(x: 160, y: 110))
        let subpath1 = VectorSubpath(points: [p2, p3], isClosed: false)

        let model = VectorModel(
            subpaths: [subpath0, subpath1],
            stroke: VectorStrokeStyle(color: PaletteColor(red: 1, green: 0, blue: 0), width: 2)
        )
        session.document?.layers[0].vector = model
        session.redrawVector(at: 0)

        let layer = session.document!.layers[0]
        let viewP3 = session.viewport.viewPoint(from: p3.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let target = session.resolveDirectSelectionContextualTarget(at: viewP3)
        #expect(target?.anchorIndex == VectorAnchorIndex(subpathIndex: 1, anchorIndex: 1))
    }

    // 50. Section 13: Empty-space hit returns no vector target
    @Test func contextualTargetReturnsNilForEmptySpace() {
        let session = makeSession()
        _ = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let outsideView = CGPoint(x: 290, y: 290)
        let target = session.resolveDirectSelectionContextualTarget(at: outsideView)
        #expect(target == nil)
        #expect(session.contextualHitTarget == nil)
    }

    // 51. Section 13: Secondary-click target resolution does not modify the vector model
    @Test func contextualTargetResolutionDoesNotModifyVectorModel() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialVector = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        let pt0 = initialVector.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)

        let currentVector = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        #expect(currentVector == initialVector)
    }

    // 52. Section 13: Secondary-click target resolution does not modify LayerTransform
    @Test func contextualTargetResolutionDoesNotModifyLayerTransform() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialTransform = session.document!.layers.first(where: { $0.id == layerID })!.transform
        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(initialTransform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)

        let currentTransform = session.document!.layers.first(where: { $0.id == layerID })!.transform
        #expect(currentTransform == initialTransform)
    }

    // 53. Section 13: Secondary-click target resolution creates no history transaction
    @Test func contextualTargetResolutionCreatesNoHistoryTransaction() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistoryCount = session.history.undoCount
        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)

        #expect(session.history.undoCount == initialHistoryCount)
    }

    // 54. Secondary click selects unselected anchor
    @Test func secondaryClickSelectsUnselectedAnchor() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        #expect(session.vectorSelection == nil)

        let pt1 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[1]
        let docPt = pt1.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        let target = session.resolveDirectSelectionContextualTarget(at: viewPt)
        #expect(target != nil)
        #expect(session.vectorSelection?.selectedAnchors == [VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)])
    }

    // 55. Secondary click preserves already selected anchors
    @Test func secondaryClickPreservesAlreadySelectedAnchors() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        session.selectVectorAnchor(a1, in: layerID, toggle: true)
        #expect(session.vectorSelection?.selectedAnchors.count == 2)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)
        #expect(session.vectorSelection?.selectedAnchors == [a0, a1])
    }

    // 56. Secondary click does not start drag
    @Test func secondaryClickDoesNotStartDrag() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)
        #expect(session.directSelectionDrag == nil)
    }

    // 57. Deselecting clears contextual target and selection
    @Test func deselectingContextualTargetClearsState() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let pt0 = session.document!.layers.first(where: { $0.id == layerID })!.vector!.subpaths[0].points[0]
        let docPt = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == layerID })!.transform.layerToDocument)
        let viewPt = session.viewport.viewPoint(from: docPt, documentSize: session.document!.size)

        _ = session.resolveDirectSelectionContextualTarget(at: viewPt)
        #expect(session.contextualHitTarget != nil)
        #expect(session.vectorSelection != nil)

        session.deselectVectorAnchors()
        #expect(session.contextualHitTarget == nil)
        #expect(session.vectorSelection == nil)
    }

    // 58. History ordering audit: Pen commit, anchor drag, handle drag, layer transform
    @Test func historyOrderingAudit() {
        let session = makeSession()
        session.history.reset()
        #expect(session.history.undoCount == 0)

        // A = Pen commit
        session.selectTool(.pen)
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.dragPen(to: CGPoint(x: 50, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 80, y: 80))
        session.endPenDrag()
        session.finishPen()

        #expect(session.history.undoCount == 1)
        #expect(session.history.undoName == "New Vector Layer")
        let vectorLayerID = session.activeLayerID!

        // B = Anchor drag
        session.selectTool(.directSelection)
        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let pt0 = session.document!.layers.first(where: { $0.id == vectorLayerID })!.vector!.subpaths[0].points[0]
        let docPt0 = pt0.anchor.applying(session.document!.layers.first(where: { $0.id == vectorLayerID })!.transform.layerToDocument)
        session.beginDirectSelectionDrag(at: docPt0, clickedAnchor: a0, in: vectorLayerID, toggle: false)
        session.dragDirectSelection(to: CGPoint(x: docPt0.x + 10, y: docPt0.y + 10))
        session.endDirectSelectionDrag()

        #expect(session.history.undoCount == 2)
        #expect(session.history.undoName == "Move Vector Anchor")

        // C = Handle drag
        let targetHandle = DirectSelectionHitTarget(layerID: vectorLayerID, anchorIndex: a0, kind: .handle(.next))
        session.beginDirectSelectionHandleDrag(at: CGPoint(x: docPt0.x + 10, y: docPt0.y + 10), target: targetHandle, side: .next)
        session.dragDirectSelection(to: CGPoint(x: docPt0.x + 25, y: docPt0.y + 25))
        session.endDirectSelectionDrag()

        #expect(session.history.undoCount == 3)
        #expect(session.history.undoName == "Move Vector Handle")

        // D = Layer transform
        session.selectTool(.move)
        session.beginTransform(persistent: false)
        var draft = session.transformEdit!.draft
        draft.origin.x += 15
        draft.origin.y += 15
        session.previewTransform(draft)
        session.commitTransform()

        #expect(session.history.undoCount == 4)
        #expect(session.history.undoName == "Transform Layer")

        // Test Undo sequence: D -> C -> B -> A
        #expect(session.history.undoName == "Transform Layer")
        session.undo()
        #expect(session.history.undoCount == 3)
        #expect(session.history.undoName == "Move Vector Handle")

        session.undo()
        #expect(session.history.undoCount == 2)
        #expect(session.history.undoName == "Move Vector Anchor")

        session.undo()
        #expect(session.history.undoCount == 1)
        #expect(session.history.undoName == "New Vector Layer")

        session.undo()
        #expect(session.history.undoCount == 0)
        #expect(!session.history.canUndo)

        // Test Redo sequence: A -> B -> C -> D
        #expect(session.history.redoName == "New Vector Layer")
        session.redo()
        #expect(session.history.undoCount == 1)
        #expect(session.history.undoName == "New Vector Layer")

        #expect(session.history.redoName == "Move Vector Anchor")
        session.redo()
        #expect(session.history.undoCount == 2)
        #expect(session.history.undoName == "Move Vector Anchor")

        #expect(session.history.redoName == "Move Vector Handle")
        session.redo()
        #expect(session.history.undoCount == 3)
        #expect(session.history.undoName == "Move Vector Handle")

        #expect(session.history.redoName == "Transform Layer")
        session.redo()
        #expect(session.history.undoCount == 4)
        #expect(session.history.undoName == "Transform Layer")
    }

    // 59. Corrected pen interaction undo behavior: Cmd+Z during active drafting undos transient draft, NOT prior document history
    @Test func uncommittedPenInteractionUndoBehavior() {
        let session = makeSession()
        session.history.reset()
        session.addBlankLayer()
        #expect(session.history.undoCount == 1)
        #expect(session.history.undoName == "New Blank Layer")

        // User selects Pen tool and places 2 anchor points
        session.selectTool(.pen)
        session.beginPen(at: CGPoint(x: 30, y: 30))
        session.endPenDrag()
        session.beginPen(at: CGPoint(x: 60, y: 60))
        session.endPenDrag()

        #expect(session.penDraft != nil)
        #expect(session.penDraft?.subpath.points.count == 2)
        #expect(session.canUndo == true)

        // When Cmd+Z is triggered while penDraft is active:
        session.undo()

        // Prior layer operation is NOT popped
        #expect(session.history.undoCount == 1)
        #expect(session.history.undoName == "New Blank Layer")
        // penDraft removes the last anchor
        #expect(session.penDraft != nil)
        #expect(session.penDraft?.subpath.points.count == 1)
    }

    private func sessionWithVectorLayer() -> (EditorSession, UUID) {
        let session = makeSession()
        let p0 = VectorPoint(anchor: CGPoint(x: 20, y: 20))
        let p1 = VectorPoint(anchor: CGPoint(x: 60, y: 80))
        let p2 = VectorPoint(anchor: CGPoint(x: 100, y: 30))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p0, p1, p2])],
                                stroke: VectorStrokeStyle(color: .black, width: 2))
        let image = try! VectorRenderer.render(model, in: CGSize(width: 120, height: 100))
        session.addPixelLayer(image, at: .zero, name: "Vector", editName: "Add Vector", vector: model)
        return (session, session.activeLayerID!)
    }

    // 60. Delete one selected anchor
    @Test func deleteOneSelectedAnchor() {
        let (session, layerID) = sessionWithVectorLayer()
        session.selectTool(.directSelection)

        let anchor1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(anchor1, in: layerID)

        let initialLayers = session.document?.layers.count ?? 0
        let initialUndoCount = session.history.undoCount

        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector layer expected")
            return
        }

        // Layer is preserved
        #expect(session.document?.layers.count == initialLayers)
        // Anchor 1 deleted, 2 anchors remain (points at 0 and 2 from original)
        #expect(vector.subpaths[0].points.count == 2)
        #expect(vector.subpaths[0].points[0].anchor == CGPoint(x: 20, y: 20))
        #expect(vector.subpaths[0].points[1].anchor == CGPoint(x: 100, y: 30))

        // Selection is cleared
        #expect(session.vectorSelection == nil)

        // Exactly one history transaction
        #expect(session.history.undoCount == initialUndoCount + 1)
        #expect(session.history.undoName == "Delete Vector Anchor")
    }

    // 61. Delete multiple selected anchors
    @Test func deleteMultipleSelectedAnchors() {
        let session = makeSession()
        let p0 = VectorPoint(anchor: CGPoint(x: 10, y: 10))
        let p1 = VectorPoint(anchor: CGPoint(x: 30, y: 30))
        let p2 = VectorPoint(anchor: CGPoint(x: 50, y: 50))
        let p3 = VectorPoint(anchor: CGPoint(x: 70, y: 70))
        let p4 = VectorPoint(anchor: CGPoint(x: 90, y: 90))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p0, p1, p2, p3, p4])],
                                stroke: VectorStrokeStyle(color: .black, width: 2))

        let image = try! VectorRenderer.render(model, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "Vector 5", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        session.selectTool(.directSelection)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        let a3 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 3)
        session.selectVectorAnchor(a1, in: layerID)
        session.selectVectorAnchor(a3, in: layerID, toggle: true)

        #expect(session.vectorSelection?.selectedAnchors.count == 2)

        let initialUndo = session.history.undoCount
        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector layer expected")
            return
        }

        // Anchors 1 and 3 deleted; 0, 2, 4 remain (3 points total)
        #expect(vector.subpaths[0].points.count == 3)
        #expect(vector.subpaths[0].points[0].anchor == CGPoint(x: 10, y: 10))
        #expect(vector.subpaths[0].points[1].anchor == CGPoint(x: 50, y: 50))
        #expect(vector.subpaths[0].points[2].anchor == CGPoint(x: 90, y: 90))

        #expect(session.vectorSelection == nil)
        #expect(session.history.undoCount == initialUndo + 1)
        #expect(session.history.undoName == "Delete Vector Anchors")
    }

    // 62. Delete preserves neighboring anchor geometry and handles
    @Test func deletePreservesNeighboringAnchorGeometryAndHandles() {
        let session = makeSession()
        let p0 = VectorPoint(anchor: CGPoint(x: 10, y: 10), previousControl: nil, nextControl: CGPoint(x: 20, y: 10))
        let p1 = VectorPoint(anchor: CGPoint(x: 50, y: 50), previousControl: CGPoint(x: 40, y: 50), nextControl: CGPoint(x: 60, y: 50))
        let p2 = VectorPoint(anchor: CGPoint(x: 90, y: 90), previousControl: CGPoint(x: 80, y: 90), nextControl: nil)
        let model = VectorModel(subpaths: [VectorSubpath(points: [p0, p1, p2])],
                                stroke: VectorStrokeStyle(color: .black, width: 2))

        let image = try! VectorRenderer.render(model, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "Curved", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        session.selectTool(.directSelection)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a1, in: layerID)

        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        #expect(vector.subpaths[0].points.count == 2)
        // Neighboring anchors retain exact coordinates and handles
        #expect(vector.subpaths[0].points[0].anchor == CGPoint(x: 10, y: 10))
        #expect(vector.subpaths[0].points[0].nextControl == CGPoint(x: 20, y: 10))
        #expect(vector.subpaths[0].points[1].anchor == CGPoint(x: 90, y: 90))
        #expect(vector.subpaths[0].points[1].previousControl == CGPoint(x: 80, y: 90))
    }

    // 63. Delete clears selected handle belonging to deleted anchor
    @Test func deleteClearsSelectedHandleBelongingToDeletedAnchor() {
        let (session, layerID) = sessionWithVectorLayer()
        session.selectTool(.directSelection)

        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorHandle(SelectedHandle(anchorIndex: a1, side: .next), in: layerID)

        #expect(session.vectorSelection?.selectedHandle != nil)
        #expect(session.vectorSelection?.selectedHandle?.anchorIndex == a1)

        session.deleteSelectedVectorAnchors()

        #expect(session.vectorSelection == nil)
    }

    // 64. Delete preserves unrelated subpaths
    @Test func deletePreservesUnrelatedSubpaths() {
        let session = makeSession()
        let sp0 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 20, y: 20)),
            VectorPoint(anchor: CGPoint(x: 30, y: 30))
        ])
        let sp1 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 50, y: 50)),
            VectorPoint(anchor: CGPoint(x: 60, y: 60)),
            VectorPoint(anchor: CGPoint(x: 70, y: 70))
        ])
        let model = VectorModel(subpaths: [sp0, sp1], stroke: VectorStrokeStyle(color: .black, width: 2))
        let image = try! VectorRenderer.render(model, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "MultiSubpath", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        session.selectTool(.directSelection)
        let a1Sp0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a1Sp0, in: layerID)

        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        #expect(vector.subpaths.count == 2)
        #expect(vector.subpaths[0].points.count == 2)
        // Subpath 1 is completely untouched
        #expect(vector.subpaths[1] == sp1)
    }

    // 65. Empty subpath cleanup follows model invariant
    @Test func emptySubpathCleanupFollowsModelInvariant() {
        let session = makeSession()
        let sp0 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 10, y: 10)),
            VectorPoint(anchor: CGPoint(x: 20, y: 20))
        ])
        let sp1 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 50, y: 50)),
            VectorPoint(anchor: CGPoint(x: 60, y: 60))
        ])
        let model = VectorModel(subpaths: [sp0, sp1], stroke: VectorStrokeStyle(color: .black, width: 2))
        let image = try! VectorRenderer.render(model, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "TwoSubpaths", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        session.selectTool(.directSelection)
        // Select both anchors in Subpath 0
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0), in: layerID)
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1), in: layerID, toggle: true)

        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        // Subpath 0 became empty and was removed; only original Subpath 1 remains
        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0] == sp1)
    }

    // 66. Subpath with 1 anchor left is preserved
    @Test func singleAnchorSubpathPreserved() {
        let session = makeSession()
        let p0 = VectorPoint(anchor: CGPoint(x: 15, y: 15))
        let p1 = VectorPoint(anchor: CGPoint(x: 35, y: 35))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p0, p1])],
                                stroke: VectorStrokeStyle(color: .black, width: 2))
        let image = try! VectorRenderer.render(model, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "TwoPoints", editName: "Add Vector", vector: model)
        let layerID = session.activeLayerID!

        session.selectTool(.directSelection)
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1), in: layerID)

        session.deleteSelectedVectorAnchors()

        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector expected")
            return
        }

        #expect(vector.subpaths.count == 1)
        #expect(vector.subpaths[0].points.count == 1)
        #expect(vector.subpaths[0].points[0] == p0)
        #expect(vector.isValid)
    }

    // 67. Entire vector model becomes empty does not delete layer
    @Test func entireVectorModelBecomesEmptyDoesNotDeleteLayer() {
        let (session, layerID) = sessionWithVectorLayer()
        session.selectTool(.directSelection)

        // Select all 3 anchors
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0), in: layerID)
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1), in: layerID, toggle: true)
        session.selectVectorAnchor(VectorAnchorIndex(subpathIndex: 0, anchorIndex: 2), in: layerID, toggle: true)

        let initialLayers = session.document?.layers.count ?? 0
        session.deleteSelectedVectorAnchors()

        // Layer is NOT deleted
        #expect(session.document?.layers.count == initialLayers)
        guard let layer = session.document?.layers.first(where: { $0.id == layerID }),
              let vector = layer.vector else {
            Issue.record("Vector layer expected")
            return
        }

        #expect(vector.subpaths.isEmpty)
        #expect(vector.totalAnchorCount == 0)
        #expect(vector.isValid)
        #expect(session.vectorSelection == nil)
    }

    // 68. Undo and redo of anchor deletion
    @Test func undoAndRedoOfAnchorDeletion() {
        let (session, layerID) = sessionWithVectorLayer()
        session.selectTool(.directSelection)

        let originalVector = session.document!.layers.first(where: { $0.id == layerID })!.vector!

        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a1, in: layerID)

        session.deleteSelectedVectorAnchors()

        let vectorAfterDelete = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        #expect(vectorAfterDelete.subpaths[0].points.count == 2)

        // Undo restores exact pre-delete model
        session.undo()
        let vectorAfterUndo = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        #expect(vectorAfterUndo == originalVector)

        // Redo applies deletion again
        session.redo()
        let vectorAfterRedo = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        #expect(vectorAfterRedo == vectorAfterDelete)
    }

    // 69. Delete key pressed in Direct Selection routes to anchor deletion
    @Test func deleteKeyPressedInDirectSelectionRoutesToAnchorDeletion() {
        let (session, layerID) = sessionWithVectorLayer()
        session.selectTool(.directSelection)

        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a1, in: layerID)

        let initialLayers = session.document?.layers.count ?? 0

        // User hits Delete key
        session.deleteKeyPressed()

        // Layer is not deleted; anchor is deleted
        #expect(session.document?.layers.count == initialLayers)
        let vector = session.document!.layers.first(where: { $0.id == layerID })!.vector!
        #expect(vector.subpaths[0].points.count == 2)
    }

    // 70. Phase 2B-5: Visual-state evaluations for vector anchors
    @Test func visualStateEvaluationsForAnchor() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)

        // Both initially unselected
        #expect(session.visualStateForAnchor(a0, in: layerID) == .unselected)
        #expect(session.visualStateForAnchor(a1, in: layerID) == .unselected)

        // Select a0
        session.selectVectorAnchor(a0, in: layerID)
        #expect(session.visualStateForAnchor(a0, in: layerID) == .selected)
        #expect(session.visualStateForAnchor(a1, in: layerID) == .unselected)

        // Hover a1 (unselected)
        session.directSelectionHoverTarget = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a1, kind: .anchor)
        #expect(session.visualStateForAnchor(a0, in: layerID) == .selected)
        #expect(session.visualStateForAnchor(a1, in: layerID) == .hoveredUnselected)

        // Hover a0 (selected)
        session.directSelectionHoverTarget = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .anchor)
        #expect(session.visualStateForAnchor(a0, in: layerID) == .hoveredSelected)
        #expect(session.visualStateForAnchor(a1, in: layerID) == .unselected)

        // Clear hover
        session.clearDirectSelectionHover()
        #expect(session.visualStateForAnchor(a0, in: layerID) == .selected)
    }

    // 71. Phase 2B-5: Visual-state evaluations for Bézier handles
    @Test func visualStateEvaluationsForHandle() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let prevHandle = SelectedHandle(anchorIndex: a0, side: .previous)
        let nextHandle = SelectedHandle(anchorIndex: a0, side: .next)

        // Initially unselected
        #expect(session.visualStateForHandle(prevHandle, in: layerID) == .unselected)
        #expect(session.visualStateForHandle(nextHandle, in: layerID) == .unselected)

        // Select nextHandle
        session.selectVectorHandle(nextHandle, in: layerID)
        #expect(session.visualStateForHandle(nextHandle, in: layerID) == .selected)
        #expect(session.visualStateForHandle(prevHandle, in: layerID) == .unselected)

        // Hover prevHandle (unselected)
        session.directSelectionHoverTarget = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.previous))
        #expect(session.visualStateForHandle(prevHandle, in: layerID) == .hoveredUnselected)
        #expect(session.visualStateForHandle(nextHandle, in: layerID) == .selected)

        // Hover nextHandle (selected)
        session.directSelectionHoverTarget = DirectSelectionHitTarget(layerID: layerID, anchorIndex: a0, kind: .handle(.next))
        #expect(session.visualStateForHandle(nextHandle, in: layerID) == .hoveredSelected)
    }

    // 72. Phase 2B-5: Hover target updates without document or history mutation
    @Test func hoverTargetUpdatesWithoutDocumentOrHistoryMutation() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let initialHistory = session.history.undoCount
        let initialLayers = session.document?.layers.count
        let initialVector = session.document?.layers.first(where: { $0.id == layerID })?.vector

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let viewPt0 = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        // Hover over anchor 0
        let target = session.updateDirectSelectionHover(at: viewPt0)
        #expect(target != nil)
        #expect(session.directSelectionHoverTarget == target)
        #expect(target?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))

        // Document, layers, vector model, and history remain untouched
        #expect(session.history.undoCount == initialHistory)
        #expect(session.document?.layers.count == initialLayers)
        #expect(session.document?.layers.first(where: { $0.id == layerID })?.vector == initialVector)
        #expect(session.vectorSelection == nil)

        // Move to empty space clears hover
        let emptyPt = CGPoint(x: 290, y: 290)
        let cleared = session.updateDirectSelectionHover(at: emptyPt)
        #expect(cleared == nil)
        #expect(session.directSelectionHoverTarget == nil)
    }

    // 73. Phase 2B-5: Right-click on unselected anchor resolves target and returns menu
    @Test func rightClickOnUnselectedAnchorResolvesTargetAndShowsMenu() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(spot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(menu?.items.contains { $0.title == "Deselect" } == true)
        #expect(session.contextualHitTarget?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))
        #expect(session.vectorSelection?.selectedAnchors == [VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)])
    }

    // 74. Phase 2B-5: Right-click on already-selected anchor preserves multi-selection
    @Test func rightClickOnAlreadySelectedAnchorPreservesMultiSelection() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        let a1 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 1)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        session.selectVectorAnchor(a1, in: layerID, toggle: true)
        #expect(session.vectorSelection?.selectedAnchors.count == 2)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(spot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(session.vectorSelection?.selectedAnchors == [a0, a1])
        #expect(session.contextualHitTarget?.anchorIndex == a0)
    }

    // 75. Phase 2B-5: Right-click on selected handle resolves target and preserves anchor selection
    @Test func rightClickOnSelectedHandleResolvesTargetAndPreservesAnchorSelection() {
        let session = makeSession()
        let layerID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let nextDoc = layer.vector!.subpaths[0].points[0].nextControl!.applying(layer.transform.layerToDocument)
        let spot = session.viewport.viewPoint(from: nextDoc, documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(spot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(session.contextualHitTarget?.kind == .handle(.next))
        #expect(session.vectorSelection?.selectedAnchors.contains(a0) == true)
        #expect(session.vectorSelection?.selectedHandle == SelectedHandle(anchorIndex: a0, side: .next))
    }

    // 76. Phase 2B-5: Right-click on empty canvas returns nil menu and does not fabricate target
    @Test func rightClickOnEmptyCanvasReturnsNilMenuAndNoTarget() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let a0 = VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)
        session.selectVectorAnchor(a0, in: layerID, toggle: false)
        let initialHistory = session.history.undoCount

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let emptySpot = CGPoint(x: 290, y: 290)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(emptySpot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu == nil)
        #expect(session.contextualHitTarget == nil)
        // Existing selection preserved
        #expect(session.vectorSelection?.selectedAnchors == [a0])
        // No document history created
        #expect(session.history.undoCount == initialHistory)
    }

    // 77. Phase 2B-5: Right-click on another vector layer switches active layer and selects anchor
    @Test func rightClickOnAnotherVectorLayerSwitchesActiveLayerAndSelectsAnchor() {
        let session = makeSession()
        let layer1ID = createTriangleLayer(in: session)
        let layer2ID = createCurvedLayer(in: session)
        session.selectTool(.directSelection)

        // Make layer 1 active initially
        session.activeLayerID = layer1ID

        let layer2 = session.document!.layers.first(where: { $0.id == layer2ID })!
        let pt0 = layer2.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer2.transform.layerToDocument), documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: view.convert(spot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(session.activeLayerID == layer2ID)
        #expect(session.contextualHitTarget?.layerID == layer2ID)
        #expect(session.vectorSelection?.layerID == layer2ID)
    }

    // 78. Phase 2B-5: Contextual target clears on deselect and cancel
    @Test func contextualTargetClearsOnDeselectAndCancel() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        // Resolve contextual target
        session.resolveDirectSelectionContextualTarget(at: spot)
        #expect(session.contextualHitTarget != nil)

        // Deselect clears it
        session.deselectVectorAnchors()
        #expect(session.contextualHitTarget == nil)

        // Resolve again
        session.resolveDirectSelectionContextualTarget(at: spot)
        #expect(session.contextualHitTarget != nil)

        // Cancel clears it
        session.cancelDirectSelection()
        #expect(session.contextualHitTarget == nil)
    }

    // 79. Phase 2B-5: Control+click routes to secondary-click and resolves contextual target
    @Test func controlClickRoutesToSecondaryClickAndResolvesContextualTarget() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        // LeftMouseDown with .control modifier
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(spot, to: nil),
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        let menu = view.menu(for: event)
        #expect(menu != nil)
        #expect(session.contextualHitTarget?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))
        #expect(session.vectorSelection?.selectedAnchors == [VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0)])
    }

    // 80. Phase 2B-5: Mouse move updates hover target and mouse exit clears it
    @Test func mouseMoveUpdatesHoverTargetAndMouseExitClearsIt() {
        let session = makeSession()
        let layerID = createTriangleLayer(in: session)
        session.selectTool(.directSelection)

        let layer = session.document!.layers.first(where: { $0.id == layerID })!
        let pt0 = layer.vector!.subpaths[0].points[0]
        let spot = session.viewport.viewPoint(from: pt0.anchor.applying(layer.transform.layerToDocument), documentSize: session.document!.size)

        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        let moveEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: view.convert(spot, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!

        view.mouseMoved(with: moveEvent)
        #expect(session.directSelectionHoverTarget?.anchorIndex == VectorAnchorIndex(subpathIndex: 0, anchorIndex: 0))

        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: view.convert(NSPoint(x: -10, y: -10), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!

        view.mouseExited(with: exitEvent)
        #expect(session.directSelectionHoverTarget == nil)
    }
}
