import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Cropping on iPad: the Crop tool's frame under a finger, through the canvas's touch input as the Mac's mouse drives
/// it.
@MainActor struct PadCropTests {
    /// A 400 × 300 canvas fitted to a view its size, with one layer covering it, and the Crop tool in hand.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Blue"))
        session.selectTool(.crop)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// A finger dragged through `points`, in the canvas's points, Control held so nothing snaps.
    private func drag(_ input: PadCanvasInput, through points: [CGPoint]) {
        input.began(at: points[0], keys: .control)
        for point in points.dropFirst() { input.moved(to: point, keys: .control) }
        input.ended(at: points[points.count - 1], keys: .control)
    }

    /// The Crop tool starts with the whole canvas framed; a drag draws a new frame, and Apply Crop crops the canvas to it.
    @Test func aDragFramesTheCropAndApplyCropsToIt() async throws {
        let session = try session()
        #expect(session.cropRect == CGRect(x: 0, y: 0, width: 400, height: 300))
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(50, 40, in: session), point(150, 100, in: session), point(250, 190, in: session)])
        #expect(session.cropRect == CGRect(x: 50, y: 40, width: 200, height: 150))

        await session.commitCrop()
        #expect(session.document?.width == 200 && session.document?.height == 150)
        #expect(session.cropRect == nil)
    }

    /// A finger finds an edge of the frame further off than a pointer would, and drags just that edge.
    @Test func aFingerDragsAnEdgeFromFurtherOff() throws {
        let session = try session()
        let input = PadCanvasInput(session: session)
        // 15 points inside the right edge: past a pointer's 10, within a finger's 22.
        let edge = point(400, 150, in: session)
        drag(input, through: [CGPoint(x: edge.x - 15, y: edge.y), CGPoint(x: edge.x - 55, y: edge.y)])

        let rect = try #require(session.cropRect)
        #expect(rect.minX == 0 && rect.minY == 0 && rect.height == 300)
        #expect(abs(rect.maxX - (400 - 40 / session.viewport.pointsPerPixel)) <= 1)
    }

    /// A drag inside a frame smaller than the canvas moves it.
    @Test func aDragInsideMovesTheFrame() throws {
        let session = try session()
        session.cropRect = CGRect(x: 100, y: 100, width: 100, height: 80)
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(150, 140, in: session), point(180, 160, in: session)])
        #expect(session.cropRect == CGRect(x: 130, y: 120, width: 100, height: 80))
    }

    /// With a ratio chosen in the bar, a new frame keeps it.
    @Test func aFrameKeepsTheRatioChosen() throws {
        let session = try session()
        session.cropRatioChoice = "1:1"
        let input = PadCanvasInput(session: session)
        drag(input, through: [point(50, 50, in: session), point(250, 150, in: session)])
        let rect = try #require(session.cropRect)
        #expect(rect.width == rect.height)
        #expect(rect.width == 200)
    }

    /// A second finger coming down to zoom takes the drag back, leaving the frame as it was.
    @Test func aSecondFingerTakesTheDragBack() throws {
        let session = try session()
        let frame = CGRect(x: 100, y: 100, width: 100, height: 80)
        session.cropRect = frame
        let input = PadCanvasInput(session: session)
        input.began(at: point(150, 140, in: session), keys: .control)
        input.moved(to: point(190, 170, in: session), keys: .control)
        #expect(session.cropRect != frame)
        input.cancelled()
        #expect(session.cropRect == frame)
    }

    /// An export sets a crop in progress aside first, as on the Mac.
    @Test func anExportSetsTheCropAside() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 100)
        session.selectTool(.crop)
        session.cropRect = CGRect(x: 10, y: 10, width: 50, height: 50)
        window.exportPNG(nil)
        #expect(session.cropRect == nil)
    }
}
