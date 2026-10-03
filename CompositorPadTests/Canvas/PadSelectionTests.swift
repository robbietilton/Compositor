import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Selecting on iPad: the Marquee, Lasso and Magic tools under a finger, and moving a layer, through the canvas's
/// touch input as the Mac's mouse drives them.
@MainActor struct PadSelectionTests {
    /// A 400 × 300 canvas fitted to a view its size, with one layer covering it, red on the left half and blue on the
    /// right.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Halves"))
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// A finger dragged through `pixels`, Control held so nothing snaps.
    private func drag(_ input: PadCanvasInput, through pixels: [CGPoint], in session: EditorSession, keys: UIKeyModifierFlags = .control) {
        let points = pixels.map { point($0.x, $0.y, in: session) }
        input.began(at: points[0], keys: keys)
        for point in points.dropFirst() { input.moved(to: point, keys: keys) }
        input.ended(at: points[points.count - 1], keys: keys)
    }

    private func tap(_ input: PadCanvasInput, at pixel: CGPoint, in session: EditorSession, taps: Int = 1) {
        let point = point(pixel.x, pixel.y, in: session)
        input.began(at: point)
        input.ended(at: point, tapCount: taps)
    }

    /// A drag with the Marquee selects the rectangle it spans.
    @Test func aMarqueeDragSelectsTheRectangleItSpans() throws {
        let session = try session()
        session.selectTool(.marquee)
        session.marqueeKind = .rectangle
        let input = PadCanvasInput(session: session)
        drag(input, through: [CGPoint(x: 50, y: 40), CGPoint(x: 100, y: 80), CGPoint(x: 150, y: 120)], in: session)

        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX - 50) <= 1 && abs(bounds.minY - 40) <= 1)
        #expect(abs(bounds.width - 100) <= 1 && abs(bounds.height - 80) <= 1)
        #expect(session.lassoDraft == nil)
    }

    /// In New mode a drag inside the selection moves its outline; a tap inside it deselects, as a click does.
    @Test func aDragInsideMovesTheOutlineAndATapDeselects() throws {
        let session = try session()
        session.selectTool(.marquee)
        session.marqueeKind = .rectangle
        let input = PadCanvasInput(session: session)
        drag(input, through: [CGPoint(x: 50, y: 40), CGPoint(x: 150, y: 120)], in: session)
        drag(input, through: [CGPoint(x: 100, y: 80), CGPoint(x: 130, y: 95)], in: session)

        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX - 80) <= 1 && abs(bounds.minY - 55) <= 1)
        tap(input, at: CGPoint(x: 120, y: 100), in: session)
        #expect(session.selection == nil)
    }

    /// Add mode, chosen in the bar as Shift chooses it on a keyboard, adds the next rectangle to the selection.
    @Test func addModeAddsTheNextOutline() throws {
        let session = try session()
        session.selectTool(.marquee)
        session.marqueeKind = .rectangle
        let input = PadCanvasInput(session: session)
        drag(input, through: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], in: session)
        session.selectionModeChoice = .add
        drag(input, through: [CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 260)], in: session)

        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX - 20) <= 1 && abs(bounds.maxX - 340) <= 1)
        #expect(abs(bounds.minY - 20) <= 1 && abs(bounds.maxY - 260) <= 1)
    }

    /// A polygonal lasso puts a corner down at each tap and closes on a tap back at its first corner.
    @Test func aPolygonalLassoClosesBackAtItsFirstCorner() throws {
        let session = try session()
        session.selectTool(.lasso)
        session.lassoKind = .polygonal
        let input = PadCanvasInput(session: session)
        for corner in [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50), CGPoint(x: 300, y: 250)] {
            tap(input, at: corner, in: session)
        }
        #expect(session.lassoDraft?.points.count == 3)
        #expect(session.selection == nil)
        // A few pixels off the first corner, well within a fingertip.
        tap(input, at: CGPoint(x: 104, y: 53), in: session)

        #expect(session.lassoDraft == nil)
        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX - 100) <= 1 && abs(bounds.maxX - 300) <= 1)
    }

    /// A double tap closes a polygonal lasso wherever it lands.
    @Test func aDoubleTapClosesAPolygonalLasso() throws {
        let session = try session()
        session.selectTool(.lasso)
        session.lassoKind = .polygonal
        let input = PadCanvasInput(session: session)
        for corner in [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50), CGPoint(x: 300, y: 250)] {
            tap(input, at: corner, in: session)
        }
        tap(input, at: CGPoint(x: 100, y: 250), in: session, taps: 2)

        #expect(session.lassoDraft == nil)
        #expect(session.selection != nil)
    }

    /// A finger drawn around an area with the freehand lasso selects it.
    @Test func aFreehandLassoSelectsWhatItDrawsAround() throws {
        let session = try session()
        session.selectTool(.lasso)
        session.lassoKind = .freehand
        let input = PadCanvasInput(session: session)
        drag(input, through: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 50), CGPoint(x: 150, y: 150), CGPoint(x: 50, y: 150)],
             in: session, keys: [])

        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX - 50) <= 2 && abs(bounds.maxX - 150) <= 2)
        #expect(abs(bounds.minY - 50) <= 2 && abs(bounds.maxY - 150) <= 2)
    }

    /// A tap with the Magic Wand selects the connected pixels of the color tapped.
    @Test func theMagicWandSelectsTheColorTapped() async throws {
        let session = try session()
        session.selectTool(.wand)
        session.wandMode = .wand
        let input = PadCanvasInput(session: session)
        #expect(!input.began(at: point(60, 100, in: session)))
        await input.pending?.value

        let bounds = try #require(session.selection?.coverageBounds)
        #expect(abs(bounds.minX) <= 1 && abs(bounds.maxX - 200) <= 1)
        #expect(abs(bounds.minY) <= 1 && abs(bounds.maxY - 300) <= 1)
    }

    /// On a keyboard M, L and W choose the Marquee, Lasso and Magic tools, as on the Mac.
    @Test func theSelectionToolsHaveTheirKeys() {
        let window = EditorWindowController()
        let tools = Dictionary((window.keyCommands ?? []).compactMap { command -> (String, NavigationTool)? in
            guard let input = command.input, let raw = command.propertyList as? String,
                  let tool = NavigationTool(rawValue: raw) else { return nil }
            return (input, tool)
        }, uniquingKeysWith: { first, _ in first })
        #expect(tools["m"] == .marquee)
        #expect(tools["l"] == .lasso)
        #expect(tools["w"] == .wand)
    }

    /// The Move tool through the same input: a drag moves the layer, here without snapping.
    @Test func aDragWithTheMoveToolMovesTheLayer() throws {
        let session = try session()
        session.selectTool(.move)
        let input = PadCanvasInput(session: session)
        drag(input, through: [CGPoint(x: 200, y: 150), CGPoint(x: 230, y: 160)], in: session)
        #expect(session.activeLayer?.origin == CGPoint(x: 30, y: 10))
        #expect(session.transformEdit == nil)
    }
}
