import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// What a touch does with the brushes, the Eyedropper and the Zoom tool, fed to the canvas's input as points, as the
/// canvas feeds it touches.
@MainActor struct PadToolTouchTests {
    /// A 400 × 300 canvas fitted to a view its size, with one layer covering it: red on the left half and blue on the
    /// right, or all gray.
    private func session(_ tool: NavigationTool, halves: Bool = false) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        if halves {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        } else {
            context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        session.selectTool(tool)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// The active layer's pixel at (`x`, `y`), its red, green and blue.
    private func layerPixel(_ session: EditorSession, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = y * context.bytesPerRow + x * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// A drag with the Brush paints along it in the foreground color, as one step to undo.
    @Test func aBrushDragPaints() throws {
        let session = try session(.brush)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.brushSettings.diameter = 6
        session.brushSettings.hardness = 1
        let input = PadCanvasInput(session: session)
        let steps = session.history.undoCount

        #expect(input.began(at: point(50, 50, in: session)))
        #expect(input.isPainting)
        input.moved(to: point(100, 50, in: session))
        input.ended(at: point(150, 50, in: session))
        #expect(!input.isPainting && session.brushStroke == nil)
        #expect(try layerPixel(session, x: 100, y: 50) == (255, 0, 0))
        #expect(try layerPixel(session, x: 149, y: 50) == (255, 0, 0))
        #expect(try layerPixel(session, x: 100, y: 100) == (128, 128, 128))
        #expect(session.history.undoCount == steps + 1)
    }

    /// A stroke taken away, as by a second finger coming down to zoom, leaves the layer as it was.
    @Test func aStrokeTakenAwayLeavesNothing() throws {
        let session = try session(.brush)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        let input = PadCanvasInput(session: session)
        let steps = session.history.undoCount

        input.began(at: point(50, 50, in: session))
        input.moved(to: point(100, 50, in: session))
        input.cancelled()
        #expect(!input.isPainting && session.brushStroke == nil)
        #expect(try layerPixel(session, x: 75, y: 50) == (128, 128, 128))
        #expect(session.history.undoCount == steps)
    }

    /// A tap with the Zoom tool zooms in twice as far about the tap; a drag right zooms in smoothly, doubling for every
    /// 100 points, as on the Mac, and zooms no further when it lifts.
    @Test func theZoomToolZoomsByTapAndDrag() throws {
        let session = try session(.zoom)
        let input = PadCanvasInput(session: session)
        let start = session.viewport.zoom

        let tap = point(100, 100, in: session)
        #expect(input.began(at: tap))
        input.ended(at: tap)
        #expect(abs(session.viewport.zoom - start * 2) < 0.0001)

        let zoom = session.viewport.zoom
        let from = CGPoint(x: 200, y: 150)
        input.began(at: from)
        input.moved(to: CGPoint(x: 201, y: 150))
        #expect(session.viewport.zoom == zoom)
        input.moved(to: CGPoint(x: 300, y: 150))
        #expect(abs(session.viewport.zoom - zoom * 2) < 0.0001)
        input.ended(at: CGPoint(x: 300, y: 150))
        #expect(abs(session.viewport.zoom - zoom * 2) < 0.0001)
    }

    /// The Eyedropper takes the color under the touch as it moves, and shows it in its ring against the color it
    /// replaces until the touch lifts.
    @Test func theEyedropperTakesTheColorUnderTheTouch() throws {
        let session = try session(.eyedropper, halves: true)
        session.foregroundColor = .white
        let input = PadCanvasInput(session: session)
        var rings: [(point: CGPoint, color: PaletteColor, original: PaletteColor)?] = []
        input.sampleChanged = { rings.append($0) }

        #expect(input.began(at: point(100, 150, in: session)))
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))
        input.moved(to: point(300, 150, in: session))
        #expect(session.foregroundColor == PaletteColor(red: 0, green: 0, blue: 1))
        input.ended(at: point(300, 150, in: session))
        #expect(rings.count == 3)
        #expect(rings.first??.color == PaletteColor(red: 1, green: 0, blue: 0) && rings.first??.original == .white)
        #expect(rings.first??.point == point(100, 150, in: session))
        #expect(rings.dropFirst().first??.color == PaletteColor(red: 0, green: 0, blue: 1) && rings.dropFirst().first??.original == .white)
        #expect(rings.last! == nil)
    }
}
