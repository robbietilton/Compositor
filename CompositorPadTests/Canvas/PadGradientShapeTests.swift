import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// The Gradient and Shape tools on iPad, through the canvas's touch input as the Mac's mouse drives them.
@MainActor struct PadGradientShapeTests {
    /// A 400 × 300 canvas fitted to a view its size, with one gray layer covering it.
    private func session(_ tool: NavigationTool) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(tool)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// A finger dragged through `points`, in the canvas's points.
    private func drag(_ input: PadCanvasInput, through points: [CGPoint], keys: UIKeyModifierFlags = .control) {
        input.began(at: points[0], keys: keys)
        for point in points.dropFirst() { input.moved(to: point, keys: keys) }
        input.ended(at: points[points.count - 1], keys: keys)
    }

    private func near(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }

    /// A drag draws a gradient's line, which waits for Apply with its ends to move; a finger finds an end further off
    /// than a pointer would. Apply paints it as one step to undo.
    @Test func aDragDrawsAGradientWhoseEndsMove() async throws {
        let session = try session(.gradient)
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(50, 150, in: session), point(200, 150, in: session), point(350, 150, in: session)])
        #expect(near(session.gradientEdit?.start, CGPoint(x: 50, y: 150)))
        #expect(near(session.gradientEdit?.end, CGPoint(x: 350, y: 150)))

        // 15 points off the end: past a pointer's 10, within a finger's 22.
        let end = point(350, 150, in: session)
        drag(input, through: [CGPoint(x: end.x - 15, y: end.y), point(300, 100, in: session)])
        #expect(near(session.gradientEdit?.start, CGPoint(x: 50, y: 150)))
        #expect(near(session.gradientEdit?.end, CGPoint(x: 300, y: 100)))

        await session.commitGradient()
        #expect(session.gradientEdit == nil)
        #expect(session.history.undoName == "Gradient")
    }

    /// Shift turns the line to the nearest 45° step about its other end.
    @Test func shiftTurnsTheLineToAnEighth() throws {
        let session = try session(.gradient)
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(100, 100, in: session), point(260, 230, in: session)], keys: .shift)
        let edit = try #require(session.gradientEdit)
        #expect(abs((edit.end.x - edit.start.x) - (edit.end.y - edit.start.y)) < 0.01)
    }

    /// A second finger coming down takes the drag back: an end goes back where it was, and a new gradient goes.
    @Test func aSecondFingerTakesTheDragBack() throws {
        let session = try session(.gradient)
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(50, 150, in: session), point(350, 150, in: session)])
        input.began(at: point(350, 150, in: session))
        input.moved(to: point(300, 50, in: session))
        input.cancelled()
        #expect(near(session.gradientEdit?.end, CGPoint(x: 350, y: 150)))

        session.cancelGradient()
        input.began(at: point(50, 50, in: session))
        input.moved(to: point(150, 50, in: session))
        input.cancelled()
        #expect(session.gradientEdit == nil)
    }

    /// A drag makes a shape layer of the box it spans, in the foreground color, above the active layer.
    @Test func aDragMakesAShapeLayer() throws {
        let session = try session(.shape)
        session.shapeKind = .rectangle
        let count = session.document?.layers.count ?? 0
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(100, 100, in: session), point(150, 140, in: session), point(200, 180, in: session)])

        #expect(session.shapeDraft == nil)
        #expect(session.document?.layers.count == count + 1)
        let layer = try #require(session.activeLayer)
        #expect(layer.name == "Rectangle 1" && layer.liveShape != nil)
        #expect(layer.transform.origin == CGPoint(x: 100, y: 100) && layer.transform.size == CGSize(width: 100, height: 80))
        #expect(session.history.undoName == "Rectangle")
    }

    /// Shift makes the shape a square; a second finger takes the shape back.
    @Test func shiftSquaresTheShape() throws {
        let session = try session(.shape)
        session.shapeKind = .ellipse
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(100, 100, in: session), point(220, 160, in: session)], keys: [.shift, .control])
        let layer = try #require(session.activeLayer)
        #expect(layer.transform.size.width == layer.transform.size.height)

        let count = session.document?.layers.count ?? 0
        input.began(at: point(50, 50, in: session))
        input.moved(to: point(90, 90, in: session))
        #expect(session.shapeDraft != nil)
        input.cancelled()
        #expect(session.shapeDraft == nil && session.document?.layers.count == count)
    }
}
