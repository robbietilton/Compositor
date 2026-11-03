import AppKit
import Testing
@testable import Compositor

@MainActor
struct SelectionTests {
    private func makeSession(width: Int = 100, height: Int = 100) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height, emptyLayer: true)
        session.selectTool(.lasso)
        return session
    }
    private func lasso(_ session: EditorSession, _ points: [CGPoint], mode: SelectionMode = .replace) {
        session.beginLasso(at: points[0], mode: mode)
        for point in points.dropFirst() { session.extendLasso(to: point) }
        session.finishLasso()
    }
    private func square(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + size, y: y), CGPoint(x: x + size, y: y + size), CGPoint(x: x, y: y + size)]
    }
    /// Coverage 0–255 at a document pixel.
    private func coverage(_ session: EditorSession, _ x: Int, _ y: Int) throws -> Int {
        let document = try #require(session.document)
        let image = try #require(session.selection).coverage(width: document.width, height: document.height)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(bytes[y * image.width + x])
    }

    @Test func replaceAddAndSubtractCombineOutlines() throws {
        let session = makeSession()
        lasso(session, square(10, 10, 40))
        #expect(try coverage(session, 30, 30) == 255 && coverage(session, 70, 70) == 0)
        lasso(session, square(50, 50, 40), mode: .add)
        #expect(try coverage(session, 30, 30) == 255 && coverage(session, 70, 70) == 255)
        lasso(session, square(20, 20, 20), mode: .subtract)
        #expect(try coverage(session, 30, 30) == 0 && coverage(session, 15, 15) == 255)
        lasso(session, square(60, 10, 20))
        #expect(try coverage(session, 70, 20) == 255 && coverage(session, 70, 70) == 0 && coverage(session, 15, 15) == 0)
    }

    @Test func modifiersPickModeAndSelectionIsClippedToCanvas() throws {
        let session = makeSession()
        #expect(session.selectionMode(shift: false, option: false) == .replace)
        #expect(session.selectionMode(shift: true, option: false) == .add)
        #expect(session.selectionMode(shift: true, option: true) == .subtract)
        #expect(session.selectionMode(shift: false, option: true) == .subtract)
        lasso(session, square(-50, -50, 100))
        let bounds = try #require(session.selection).path.boundingBoxOfPath
        #expect(bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 50.001 && bounds.maxY <= 50.001)
    }

    @Test func emptySelectionIsDistinctFromNoSelection() throws {
        let session = makeSession()
        lasso(session, square(0, 0, 50), mode: .subtract)
        #expect(session.selection == nil) // Nothing to subtract from.
        lasso(session, square(10, 10, 20))
        lasso(session, square(0, 0, 60), mode: .subtract)
        let selection = try #require(session.selection)
        #expect(selection.isEmpty)
        #expect(try coverage(session, 20, 20) == 0)
        session.deselect()
        #expect(session.selection == nil)
    }

    @Test func clickDeselectsAndSelectionStepsUndo() throws {
        let session = makeSession()
        let count = session.history.undoCount
        lasso(session, square(10, 10, 40))
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Lasso")
        lasso(session, [CGPoint(x: 5, y: 5)])
        #expect(session.selection == nil && session.history.undoName == "Deselect")
        session.undo()
        #expect(session.selection?.isEmpty == false)
        session.undo()
        #expect(session.selection == nil)
        session.redo()
        #expect(try coverage(session, 30, 30) == 255)
    }

    @Test func polygonalCornersCanBeRemovedAndClosed() throws {
        let session = makeSession()
        session.lassoKind = .polygonal
        session.beginLasso(at: CGPoint(x: 10, y: 10), mode: .replace)
        session.extendLasso(to: CGPoint(x: 90, y: 10))
        session.extendLasso(to: CGPoint(x: 50, y: 50)) // Misplaced corner.
        session.removeLastLassoPoint()
        session.extendLasso(to: CGPoint(x: 90, y: 90))
        session.extendLasso(to: CGPoint(x: 10, y: 90))
        #expect(session.lassoDraft?.points.count == 4)
        session.finishLasso()
        #expect(session.history.undoName == "Polygonal Lasso")
        #expect(try coverage(session, 80, 80) == 255 && coverage(session, 5, 50) == 0)
        session.beginLasso(at: CGPoint(x: 1, y: 1), mode: .replace)
        session.cancelLasso()
        #expect(session.lassoDraft == nil && session.selection?.isEmpty == false)
    }

    @Test func antialiasingControlsEdgeCoverage() throws {
        let session = makeSession()
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)]
        lasso(session, triangle)
        // Pixels where x + y = 99 straddle the diagonal edge x + y = 100.
        let edges = try (0..<100).map { try coverage(session, $0, 99 - $0) }
        #expect(edges.contains { $0 > 0 && $0 < 255 })
        session.selectionAntialiased = false
        lasso(session, triangle)
        let hard = try (0..<100).map { try coverage(session, $0, 99 - $0) }
        #expect(hard.allSatisfy { $0 == 0 || $0 == 255 })
    }

    @Test func selectAllInverseAndToolSwitchCancelsDraft() throws {
        let session = makeSession()
        session.selectAll()
        #expect(try coverage(session, 0, 0) == 255 && coverage(session, 99, 99) == 255)
        lasso(session, square(0, 0, 50))
        session.invertSelection()
        #expect(try coverage(session, 25, 25) == 0 && coverage(session, 75, 75) == 255)
        session.beginLasso(at: CGPoint(x: 5, y: 5), mode: .replace)
        session.selectTool(.brush)
        #expect(session.lassoDraft == nil)
    }

    /// ⌘H hides the outline but keeps the selection; a different selection, or none, shows outlines again.
    /// The status bar's selection size: the Marquee as it's drawn, then the box around the selection, cut to the canvas.
    @Test func selectionSizeFollowsTheMarqueeAndStaysOnTheCanvas() {
        let session = makeSession()
        #expect(session.selectionSize == nil)
        session.selectTool(.marquee)
        session.beginLasso(at: CGPoint(x: 10, y: 20), mode: .replace)
        session.dragMarquee(to: CGPoint(x: 50, y: 35), square: false, fromCenter: false)
        #expect(session.selectionSize?.width == 40 && session.selectionSize?.height == 15)
        session.finishLasso()
        #expect(session.selectionSize?.width == 40 && session.selectionSize?.height == 15)
        lasso(session, square(70, -20, 60))
        #expect(session.selectionSize?.width == 30 && session.selectionSize?.height == 40, "cut to the canvas")
        session.deselect()
        #expect(session.selectionSize == nil)
    }

    @Test func hiddenEdgesKeepTheSelectionAndAnyNewOneShows() throws {
        let session = makeSession()
        lasso(session, square(10, 10, 20))
        session.showsSelectionEdges = false
        #expect(!session.showsSelectionEdges && session.selection?.isEmpty == false)
        lasso(session, square(40, 40, 20))
        #expect(session.showsSelectionEdges, "a new selection shows its outline")
        session.showsSelectionEdges = false
        session.deselect()
        session.selectAll()
        #expect(session.showsSelectionEdges)
    }

    /// Taking away a box whose edge meets the selection's exactly, as a box dragged past the canvas edge does once clipped,
    /// leaves no hairline for the ants to trace: neither a piece of its own nor a spur running out along the edge and
    /// back. These pairs left one before.
    @Test(arguments: [
        (CGPoint(x: 49.78979217943021, y: 43.54330466303824), CGPoint(x: 34.92413828494898, y: -9.377977037384703),
         CGPoint(x: 76.52049800780095, y: 39.0757224050528), CGPoint(x: 26.11377055953632, y: -31.636741687315578)),
        (CGPoint(x: 95.91137388899875, y: 78.58053579093038), CGPoint(x: 42.06300352639197, y: 20.348643514322127),
         CGPoint(x: 27.495646470147378, y: 55.396614491803234), CGPoint(x: 98.6680289963943, y: 80.45850546256963)),
        (CGPoint(x: -25.102024008866458, y: -4.963973014248452), CGPoint(x: 131.49154436997242, y: 30.974038857803677),
         CGPoint(x: -3.203595466171535, y: -14.504050372682055), CGPoint(x: 91.25120852295342, y: 36.95755647054405)),
        (CGPoint(x: 60.31194159740437, y: 29.979655281967936), CGPoint(x: 36.49581073573158, y: 90.93939454902221),
         CGPoint(x: 89.7907549216597, y: 30.0856538534466), CGPoint(x: -25.08151063399525, y: 66.62374348930767)),
        (CGPoint(x: -17.29301365420453, y: 26.147567173397846), CGPoint(x: 43.70803815711665, y: -14.72283655670661),
         CGPoint(x: 65.3070690463883, y: 1.3361279049343793), CGPoint(x: 9.755282700254142, y: -30.178942429392563)),
        (CGPoint(x: -26.72778948280061, y: 4.297416056427288), CGPoint(x: 92.26766856046919, y: -37.746358726636),
         CGPoint(x: 105.33729557383606, y: 48.25931253253097), CGPoint(x: 31.878872549870124, y: -37.17122527081534)),
        // As the maintainer dragged it on a 1920 × 1080 canvas, where the spur ran 900 px along the top edge.
        (CGPoint(x: -127, y: -106), CGPoint(x: 1138, y: 573), CGPoint(x: 237, y: 392), CGPoint(x: 1343, y: -415)),
    ]) func subtractingAlongAnEdgeLeavesNoHairline(box: CGPoint, to: CGPoint, cut: CGPoint, cutTo: CGPoint) throws {
        let session = EditorSession()
        let large = max(box.x, to.x, cut.x, cutTo.x) > 200
        session.createDocument(width: large ? 1920 : 100, height: large ? 1080 : 60, emptyLayer: true)
        session.selectTool(.marquee)
        marquee(session, from: box, to: to)
        marquee(session, from: cut, to: cutTo, mode: .subtract)
        #expect(try strayEdges(#require(session.selection).path).isEmpty)
    }

    /// Edges of `path` the ants would draw that don't divide selected from unselected: a quarter pixel either side of
    /// the middle of each, both are in or both are out.
    private func strayEdges(_ path: CGPath) -> [(CGPoint, CGPoint)] {
        var edges: [(CGPoint, CGPoint)] = [], start = CGPoint.zero, last = CGPoint.zero
        path.applyWithBlock { element in
            let point = element.pointee.type == .closeSubpath ? start : element.pointee.points[0]
            switch element.pointee.type {
            case .moveToPoint: start = point
            case .addLineToPoint, .closeSubpath: if point != last { edges.append((last, point)) }
            default: break
            }
            last = point
        }
        return edges.filter { from, to in
            let length = hypot(to.x - from.x, to.y - from.y)
            guard length > 0 else { return true }
            let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let normal = CGPoint(x: -(to.y - from.y) / length * 0.25, y: (to.x - from.x) / length * 0.25)
            return path.contains(CGPoint(x: middle.x + normal.x, y: middle.y + normal.y), using: .winding)
                == path.contains(CGPoint(x: middle.x - normal.x, y: middle.y - normal.y), using: .winding)
        }
    }

    /// Boxes cut one after another from a selection touching the canvas's top and left, as the maintainer drew them on
    /// a 1920 × 1080 canvas: the last, over the corner, came back drawn as a second outline over the first, the cut-away
    /// stretches of the canvas edge still marching.
    @Test func cuttingAwayAtACornerLeavesNoOutlineOverTheCut() throws {
        let session = EditorSession()
        session.createDocument(width: 1920, height: 1080, emptyLayer: true)
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGPath {
            CGPath(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), transform: nil)
        }
        session.applySelection(box(-177, -86, 1092, 598), mode: .replace, name: "Rectangular Marquee")
        session.applySelection(box(330, -90, 643, 350), mode: .subtract, name: "Rectangular Marquee")
        session.applySelection(box(795, 0, 931, 295), mode: .subtract, name: "Rectangular Marquee")
        session.applySelection(box(-46, -245, 214, 271), mode: .subtract, name: "Rectangular Marquee")
        let path = try #require(session.selection).path
        #expect(strayEdges(path).isEmpty, "\(strayEdges(path))")
        #expect(try coverage(session, 100, 100) == 0 && coverage(session, 100, 300) == 255 && coverage(session, 250, 10) == 255)
    }

    /// ⌘H hides the outline and the guides together and brings both back; guides turned off with ⌘; stay off.
    @Test func extrasHideTheOutlineAndGuidesTogether() throws {
        let session = makeSession()
        let guides = session.showsGuides
        defer { session.showsGuides = guides }
        session.showsGuides = true
        lasso(session, square(10, 10, 20))
        session.showsExtras = false
        #expect(!session.showsSelectionEdges && !session.showsGuides && session.selection?.isEmpty == false)
        session.showsExtras = true
        #expect(session.showsSelectionEdges && session.showsGuides)
        session.showsGuides = false
        session.showsExtras = false
        session.showsExtras = true
        #expect(session.showsSelectionEdges && !session.showsGuides, "⌘H doesn't turn on guides ⌘; turned off")
    }

    /// Select All then Inverse leaves nothing selected, as in Photoshop, so painting works everywhere again.
    @Test func inverseOfEverythingDeselects() throws {
        let session = makeSession()
        session.selectAll()
        session.invertSelection()
        #expect(session.selection == nil)
        session.undo()
        #expect(session.selection?.isEmpty == false)
    }

    @Test func cursorBadgeFollowsModifiersButKeepsAnOutlinesStartingMode() {
        let session = makeSession()
        #expect(session.lassoCursorMode(shift: false, option: false) == .replace)
        #expect(session.lassoCursorMode(shift: true, option: false) == .add)
        #expect(session.lassoCursorMode(shift: false, option: true) == .subtract)
        session.selectionModeChoice = .add
        #expect(session.lassoCursorMode(shift: false, option: false) == .add)
        session.beginLasso(at: CGPoint(x: 5, y: 5), mode: .subtract)
        #expect(session.lassoCursorMode(shift: false, option: false) == .subtract)
        #expect(session.lassoCursorMode(shift: true, option: false) == .subtract)
        session.cancelLasso()
        session.selectionModeChoice = .replace
        session.updateHeldSelectionKeys(shift: true, option: false)
        #expect(session.displayedSelectionMode == .add && session.selectionModeChoice == .replace)
        session.updateHeldSelectionKeys(shift: true, option: true)
        #expect(session.displayedSelectionMode == .subtract)
        session.updateHeldSelectionKeys(shift: false, option: false)
        #expect(session.displayedSelectionMode == .replace)
        #expect(CanvasView.selectionCursors.values.allSatisfy { $0.count == 3 && $0[.replace] != nil })
    }

    @Test func draggingMovesTheOutlineInWholePixelsAsOneUndo() throws {
        let session = makeSession()
        lasso(session, square(10, 10, 20))
        #expect(session.canMoveSelection(at: CGPoint(x: 20, y: 20)))
        #expect(!session.canMoveSelection(at: CGPoint(x: 60, y: 60)))
        let count = session.history.undoCount
        #expect(session.beginSelectionMove())
        session.moveSelection(by: CGSize(width: 10.4, height: 29.6))
        session.moveSelection(by: CGSize(width: 40.2, height: 40.4))
        session.endSelectionMove()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Move Selection")
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 50, y: 50, width: 20, height: 20))
        #expect(try coverage(session, 55, 55) == 255 && coverage(session, 15, 15) == 0)
        session.undo()
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    @Test func movingOffCanvasAndBackKeepsTheWholeShape() throws {
        let session = makeSession()
        lasso(session, square(10, 10, 20))
        #expect(session.beginSelectionMove())
        session.moveSelection(by: CGSize(width: -25, height: 0))
        session.endSelectionMove()
        #expect(try coverage(session, 0, 20) == 255)
        #expect(session.beginSelectionMove())
        session.moveSelection(by: CGSize(width: 25, height: 0))
        session.endSelectionMove()
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    @Test func arrowNudgesAndMoveIsOnlyForNewModeOnARealSelection() throws {
        let session = makeSession()
        #expect(!session.beginSelectionMove()) // Nothing selected.
        lasso(session, square(10, 10, 20))
        let count = session.history.undoCount
        session.nudgeSelection(dx: 1, dy: 0)
        session.nudgeSelection(dx: 0, dy: -10)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 11, y: 0, width: 20, height: 20))
        #expect(session.history.undoCount == count + 2)
        #expect(session.selectionMode(shift: true, option: false) != .replace) // Shift draws an added outline instead.
        session.beginLasso(at: CGPoint(x: 5, y: 5), mode: .add)
        #expect(!session.canMoveSelection(at: CGPoint(x: 20, y: 10)))
        session.cancelLasso()
        lasso(session, square(0, 0, 60), mode: .subtract)
        #expect(session.selection?.isEmpty == true && !session.beginSelectionMove())
    }

    @Test func expandAndContractGrowAndShrinkTheOutline() throws {
        let session = makeSession()
        #expect(!session.canModifySelection)
        lasso(session, square(40, 40, 20))
        #expect(session.canModifySelection)
        session.expandSelection(by: 5)
        #expect(session.history.undoName == "Expand Selection")
        let grown = try #require(session.selection).path.boundingBoxOfPath
        #expect(abs(grown.minX - 35) < 0.01 && abs(grown.width - 30) < 0.01)
        #expect(try coverage(session, 37, 50) == 255 && coverage(session, 33, 50) == 0)
        session.contractSelection(by: 8)
        let shrunk = try #require(session.selection).path.boundingBoxOfPath
        #expect(abs(shrunk.minX - 43) < 0.01 && abs(shrunk.width - 14) < 0.01)
        session.undo()
        #expect(abs(try #require(session.selection).path.boundingBoxOfPath.width - 30) < 0.01)
    }

    @Test func expandStaysOnCanvasAndContractCanEmptyTheSelection() throws {
        let session = makeSession()
        session.selectAll()
        session.expandSelection(by: 10)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 100, height: 100))
        session.contractSelection(by: 10) // Pulls in from the canvas edges too.
        #expect(try coverage(session, 5, 50) == 0 && coverage(session, 50, 50) == 255)
        session.contractSelection(by: 45)
        #expect(session.selection?.isEmpty == true)
        #expect(!session.canModifySelection)
    }

    /// A mask with a black square (hidden) and a white square hole inside it.
    private func maskedLayer(_ session: EditorSession) throws -> UUID {
        let id = try #require(session.activeLayerID)
        let context = try BrushRaster.context(width: 100, height: 100, mask: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 20, y: 30, width: 40, height: 40))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 30, y: 40, width: 10, height: 10))
        let asset = try LayerMask.asset(from: try #require(context.makeImage()))
        session.addLayerMask(revealing: true)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].mask = LayerMask(asset: asset)
        return id
    }

    @Test func cmdClickingAMaskSelectsItsBlackAreas() throws {
        let session = makeSession()
        let id = try maskedLayer(session)
        session.loadMaskSelection(layerID: id)
        #expect(session.history.undoName == "Load Mask Selection")
        #expect(try coverage(session, 25, 35) == 255)   // Black: selected.
        #expect(try coverage(session, 35, 45) == 0)     // White hole: not selected.
        #expect(try coverage(session, 80, 80) == 0)     // White surroundings.
        #expect(try coverage(session, 59, 69) == 255 && coverage(session, 60, 70) == 0) // Exact pixel edges.
        // Shift adds and Option subtracts, like Cmd-Shift / Cmd-Option clicks.
        lasso(session, square(80, 80, 10))
        session.loadMaskSelection(layerID: id, mode: .add)
        #expect(try coverage(session, 85, 85) == 255 && coverage(session, 25, 35) == 255)
        session.loadMaskSelection(layerID: id, mode: .subtract)
        #expect(try coverage(session, 85, 85) == 255 && coverage(session, 25, 35) == 0)
    }

    @Test func maskSelectionFollowsTheLayerTransformAndIgnoresAllWhiteMasks() throws {
        let session = makeSession(width: 200, height: 200)
        let id = try maskedLayer(session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        // The layer and its mask stretched 2× from the canvas origin.
        session.document?.layers[index].transform = LayerTransform(origin: .zero, size: CGSize(width: 200, height: 200))
        session.loadMaskSelection(layerID: id)
        let bounds = try #require(session.selection).path.boundingBoxOfPath
        #expect(bounds == CGRect(x: 40, y: 60, width: 80, height: 80))
        session.deselect()
        session.addBlankLayer()
        session.addLayerMask(revealing: true)
        session.loadMaskSelection(layerID: try #require(session.activeLayerID))
        #expect(session.selection == nil) // No black anywhere: nothing to select.
    }

    @Test func cmdClickingALayerSelectsItsOpaquePixels() throws {
        let session = makeSession(width: 200, height: 200)
        // A 50×50 image: opaque ring with a transparent center, faint (25%) corner pixel.
        let context = try BrushRaster.context(width: 50, height: 50, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 30, height: 30))
        context.clear(CGRect(x: 20, y: 20, width: 10, height: 10))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.25))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Ring"))
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 50, y: 50), size: CGSize(width: 100, height: 100))
        session.loadLayerSelection(layerID: id)
        #expect(session.history.undoName == "Load Layer Selection")
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 70, y: 70, width: 60, height: 60)) // 2× scale.
        #expect(try coverage(session, 75, 75) == 255)   // Opaque ring.
        #expect(try coverage(session, 100, 100) == 0)   // Transparent center.
        #expect(try coverage(session, 50, 50) == 0)     // 25% pixel is under the threshold.
        lasso(session, square(0, 0, 20))
        session.loadLayerSelection(layerID: id, mode: .add)
        #expect(try coverage(session, 10, 10) == 255 && coverage(session, 75, 75) == 255)
        session.addBlankLayer()
        let before = session.selection
        session.loadLayerSelection(layerID: try #require(session.activeLayerID))
        #expect(session.selection == before) // An empty layer selects nothing.
    }

    private func marquee(_ session: EditorSession, from start: CGPoint, to end: CGPoint, mode: SelectionMode = .replace,
                         square: Bool = false, fromCenter: Bool = false) {
        session.beginLasso(at: start, mode: mode)
        session.dragMarquee(to: end, square: square, fromCenter: fromCenter)
        session.finishLasso()
    }

    @Test func marqueeDrawsWholePixelRectanglesInAnyDirection() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        marquee(session, from: CGPoint(x: 60.4, y: 70.6), to: CGPoint(x: 20.2, y: 30.3))
        #expect(session.history.undoName == "Rectangular Marquee")
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 20, y: 30, width: 40, height: 41))
        #expect(try coverage(session, 20, 30) == 255 && coverage(session, 19, 30) == 0)
        marquee(session, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 90, y: 90), mode: .add)
        #expect(try coverage(session, 85, 85) == 255 && coverage(session, 40, 50) == 255)
        marquee(session, from: CGPoint(x: 30, y: 40), to: CGPoint(x: 50, y: 60), mode: .subtract)
        #expect(try coverage(session, 40, 50) == 0 && coverage(session, 25, 35) == 255)
        marquee(session, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)) // A click deselects.
        #expect(session.selection == nil)
    }

    @Test func marqueeShiftMakesSquaresAndCenteredDragsGrowFromTheAnchor() {
        let session = makeSession()
        session.selectTool(.marquee)
        marquee(session, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 20), square: true)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 30, height: 30))
        marquee(session, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 60, y: 55), fromCenter: true)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 40, y: 45, width: 20, height: 10))
        marquee(session, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 45, y: 58), square: true, fromCenter: true)
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 42, y: 42, width: 16, height: 16))
        // Object selection is the Magic tool's Object mode now, not a tool of its own (EditorSession: "Tab
        // switches Wand and Object"), so the tool that carries it is `.wand`. This read `.objectSelection`.
        #expect(NavigationTool.marquee.isSelectionTool && NavigationTool.wand.isSelectionTool && !NavigationTool.brush.isSelectionTool)
    }

    @Test func marqueeEllipseSelectsAnOvalInItsBoxAndShiftMakesACircle() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        session.marqueeKind = .ellipse
        session.beginLasso(at: CGPoint(x: 10, y: 20), mode: .replace)
        session.dragMarquee(to: CGPoint(x: 70, y: 60), square: false, fromCenter: false)
        session.finishLasso()
        let bounds = try #require(session.selection?.path.boundingBoxOfPath)
        #expect(abs(bounds.minX - 10) < 0.5 && abs(bounds.maxX - 70) < 0.5 && abs(bounds.minY - 20) < 0.5 && abs(bounds.maxY - 60) < 0.5)
        #expect(try coverage(session, 40, 40) == 255) // the middle
        #expect(try coverage(session, 11, 21) == 0)   // the box's corner lies outside the oval
        session.beginLasso(at: CGPoint(x: 5, y: 5), mode: .replace)
        session.dragMarquee(to: CGPoint(x: 45, y: 25), square: true, fromCenter: false)
        session.finishLasso()
        let circle = try #require(session.selection?.path.boundingBoxOfPath)
        #expect(abs(circle.width - circle.height) < 0.5)
        session.toggleMarqueeKind()
        #expect(session.marqueeKind == .rectangle)
    }

    /// Space held mid-drag moves the Marquee: its starting corner goes with the far one, so the box keeps its size.
    @Test func movingTheMarqueeAnchorMovesTheBoxWithoutResizingIt() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        session.beginLasso(at: CGPoint(x: 10, y: 10), mode: .replace)
        session.dragMarquee(to: CGPoint(x: 30, y: 25), square: false, fromCenter: false)
        session.moveMarqueeAnchor(to: CGPoint(x: 40, y: 50))
        session.dragMarquee(to: CGPoint(x: 60, y: 65), square: false, fromCenter: false)
        session.finishLasso()
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 40, y: 50, width: 20, height: 15))
    }

    /// Option on the Marquee subtracts; unlike the Transform tool, it must not draw from the center.
    @Test func optionDraggingTheMarqueeSubtractsWithoutDrawingFromTheCenter() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        session.selectAll()
        let size = CGSize(width: 100, height: 100)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let spot = session.viewport.viewPoint(from: point, documentSize: size)
            return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: spot.x, y: view.bounds.height - spot.y),
                modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 40, y: 40)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 60, y: 60)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 60, y: 60)))
        #expect(try coverage(session, 50, 50) == 0)   // the dragged box is subtracted
        #expect(try coverage(session, 30, 30) == 255) // a box grown from its center would have reached here
    }

    /// M chooses the Marquee in whichever shape it was last set to; the shape is switched in the tool bar only
    /// (`pressMarqueeKey`). M used to cycle Rectangle/Ellipse, and this test asserted that.
    ///
    /// It also asserted that holding M down did not keep switching, which is gone rather than moved: the
    /// `!event.isARepeat` guard in `EditorCanvas` cannot be observed any more. `pressMarqueeKey` is
    /// `selectTool(.marquee)`, and `selectTool` returns early once that tool is current, so removing the guard
    /// would change nothing a test could see. An assertion for it would pass whether the guard were there or
    /// not, which is worse than not having one.
    @Test func mKeyChoosesTheMarqueeAndKeepsTheShapeLastSet() throws {
        let session = makeSession()
        let view = CanvasView(session: session)
        func pressM(repeat isARepeat: Bool = false) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "m", charactersIgnoringModifiers: "m", isARepeat: isARepeat, keyCode: 46)))
        }
        #expect(session.tool == .lasso && session.marqueeKind == .rectangle)
        try pressM()
        #expect(session.tool == .marquee && session.marqueeKind == .rectangle)
        try pressM()
        #expect(session.marqueeKind == .rectangle, "pressing M again must not switch the shape")
        session.marqueeKind = .ellipse
        session.selectTool(.brush)
        try pressM()
        #expect(session.tool == .marquee && session.marqueeKind == .ellipse, "the shape stays as last set")
    }

    /// Shift held as a Marquee drag starts adds without squaring the box; letting Shift go and pressing it
    /// again during the drag squares it, as in Photoshop.
    @Test func shiftStartsAnAddAndOnlyAFreshShiftSquaresTheMarquee() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        session.applySelection(CGPath(rect: CGRect(x: 5, y: 5, width: 10, height: 10), transform: nil), mode: .replace, name: "Select")
        let size = CGSize(width: 100, height: 100)
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, shift: Bool) throws {
            let spot = session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: size)
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: spot.x, y: view.bounds.height - spot.y),
                modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        // Shift held throughout: an add, box 40–70 × 40–50, not squared.
        try send(.leftMouseDown, 40, 40, shift: true)
        try send(.leftMouseDragged, 70, 50, shift: true)
        try send(.leftMouseUp, 70, 50, shift: true)
        #expect(try coverage(session, 10, 10) == 255, "the earlier selection is kept")
        #expect(try coverage(session, 65, 45) == 255)
        #expect(try coverage(session, 65, 60) == 0, "a Shift held from the press must not square the box")

        // Shift let go and pressed again mid-drag: squared to 20–40 × 60–80.
        try send(.leftMouseDown, 20, 60, shift: true)
        try send(.leftMouseDragged, 30, 65, shift: true)
        try send(.leftMouseDragged, 35, 68, shift: false)
        try send(.leftMouseDragged, 40, 70, shift: true)
        try send(.leftMouseUp, 40, 70, shift: true)
        #expect(try coverage(session, 30, 75) == 255, "a fresh Shift squares the box")
        #expect(try coverage(session, 65, 45) == 255 && coverage(session, 10, 10) == 255, "still adding")
    }

    /// L chooses the Lasso, and Freehand/Polygonal is switched in the tool bar only - the same rule as M, and
    /// the same story about the repeat assertion; see `mKeyChoosesTheMarqueeAndKeepsTheShapeLastSet`.
    @Test func lKeyChoosesTheLassoAndKeepsTheModeLastSet() throws {
        let session = makeSession()
        session.selectTool(.marquee)
        let view = CanvasView(session: session)
        func pressL(repeat isARepeat: Bool = false) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: isARepeat, keyCode: 37)))
        }
        #expect(session.lassoKind == .freehand)
        try pressL()
        #expect(session.tool == .lasso && session.lassoKind == .freehand)
        try pressL()
        #expect(session.lassoKind == .freehand, "pressing L again must not switch the mode")
        session.lassoKind = .polygonal
        session.selectTool(.brush)
        try pressL()
        #expect(session.tool == .lasso && session.lassoKind == .polygonal, "the mode stays as last set")
    }
}
