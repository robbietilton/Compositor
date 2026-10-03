import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Shift and Option with the brushes, the Gradient and the Zoom tool on a hardware keyboard, as the Mac's: Shift draws
/// straight lines, Option samples a color or zooms out.
@MainActor struct PadBrushModifierTests {
    /// A 400 × 300 canvas fitted to a view its size, with one layer covering it: red on the left half and blue on the
    /// right, or all gray; and a small hard red brush.
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
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.brushSettings.diameter = 6
        session.brushSettings.hardness = 1
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

    /// A drag through document pixels `pixels`, with `keys` held at each point.
    private func drag(_ input: PadCanvasInput, through pixels: [(CGPoint, UIKeyModifierFlags)]) {
        let session = input.session
        input.began(at: point(pixels[0].0.x, pixels[0].0.y, in: session), keys: pixels[0].1)
        for (pixel, keys) in pixels.dropFirst() { input.moved(to: point(pixel.x, pixel.y, in: session), keys: keys) }
        let last = pixels[pixels.count - 1]
        input.ended(at: point(last.0.x, last.0.y, in: session), keys: last.1)
    }

    private let red = (r: 255, g: 0, b: 0), gray = (r: 128, g: 128, b: 128)

    // MARK: Shift

    /// Shift with a tap paints a straight line on from where the last stroke ended, as on the Mac.
    @Test func shiftTapPaintsALineFromTheLastStroke() throws {
        let session = try session(.brush)
        let input = PadCanvasInput(session: session)
        drag(input, through: [(CGPoint(x: 50, y: 50), []), (CGPoint(x: 100, y: 50), [])])
        let tap = point(100, 150, in: session)
        input.began(at: tap, keys: .shift)
        input.ended(at: tap, keys: .shift)
        #expect(try layerPixel(session, x: 100, y: 100) == red)
        #expect(try layerPixel(session, x: 120, y: 100) == gray)
    }

    /// Shift held keeps the stroke on the axis its first few pixels go along, to its very end.
    @Test func shiftKeepsAStrokeStraight() throws {
        let session = try session(.brush)
        let input = PadCanvasInput(session: session)
        drag(input, through: [(CGPoint(x: 50, y: 100), .shift), (CGPoint(x: 90, y: 104), .shift), (CGPoint(x: 120, y: 110), .shift)])
        #expect(try layerPixel(session, x: 120, y: 100) == red)
        #expect(try layerPixel(session, x: 120, y: 110) == gray)
        #expect(try layerPixel(session, x: 120, y: 106) == gray)
    }

    /// Shift pressed mid-stroke locks it from where it had got to; let go, the stroke carries on freehand.
    @Test func shiftMidStrokeLocksFromThereUntilLetGo() throws {
        let session = try session(.brush)
        let input = PadCanvasInput(session: session)
        drag(input, through: [(CGPoint(x: 50, y: 100), []), (CGPoint(x: 80, y: 100), []), (CGPoint(x: 120, y: 120), .shift),
                              (CGPoint(x: 160, y: 112), .shift), (CGPoint(x: 160, y: 160), [])])
        #expect(try layerPixel(session, x: 120, y: 100) == red)
        #expect(try layerPixel(session, x: 120, y: 120) == gray)
        #expect(try layerPixel(session, x: 160, y: 140) == red)
    }

    // MARK: Option

    /// Option with the Brush samples a color, as the Eyedropper does, and paints nothing.
    @Test func optionWithTheBrushSamplesAColor() throws {
        let session = try session(.brush, halves: true)
        session.foregroundColor = .white
        let input = PadCanvasInput(session: session)
        var rings = 0
        input.sampleChanged = { if $0 != nil { rings += 1 } }
        let steps = session.history.undoCount
        let tap = point(100, 150, in: session)
        #expect(input.began(at: tap, keys: .alternate))
        #expect(session.brushStroke == nil && !input.isPainting)
        input.ended(at: tap, keys: .alternate)
        #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))
        #expect(rings == 1)
        #expect(session.history.undoCount == steps)
        #expect(try layerPixel(session, x: 100, y: 150) == red)
    }

    /// So it does with Spot Healing and the Gradient, which then draws no gradient.
    @Test func optionWithSpotHealingAndTheGradientSamplesAColor() throws {
        for tool in [NavigationTool.spotHealing, .gradient] {
            let session = try session(tool, halves: true)
            session.foregroundColor = .white
            let input = PadCanvasInput(session: session)
            drag(input, through: [(CGPoint(x: 300, y: 150), .alternate), (CGPoint(x: 320, y: 160), .alternate)])
            #expect(session.foregroundColor == PaletteColor(red: 0, green: 0, blue: 1), "\(tool)")
            #expect(session.gradientEdit == nil && session.brushStroke == nil, "\(tool)")
        }
    }

    /// Smear takes no Option, as on the Mac: it smears.
    @Test func optionWithSmearStillSmears() throws {
        let session = try session(.blur, halves: true)
        session.foregroundColor = .white
        let input = PadCanvasInput(session: session)
        input.began(at: point(180, 150, in: session), keys: .alternate)
        #expect(input.isPainting)
        #expect(session.foregroundColor == .white)
        input.cancelled()
    }

    /// Once Apple Pencil has painted, a finger with Option samples rather than moving the canvas, as it sets Clone
    /// Stamp's source; Space still moves it.
    @Test func aFingerWithOptionSamples() {
        #expect(!PadCanvasView.touchMovesCanvas(tool: .brush, pencil: false, fingerPaints: false, option: true))
        #expect(!PadCanvasView.touchMovesCanvas(tool: .gradient, pencil: false, fingerPaints: false, option: true))
        #expect(PadCanvasView.touchMovesCanvas(tool: .blur, pencil: false, fingerPaints: false, option: true))
        #expect(PadCanvasView.touchMovesCanvas(tool: .brush, pencil: false, fingerPaints: false, spaceHeld: true, option: true))
    }

    // MARK: Zoom

    /// Option with a tap of the Zoom tool zooms out by half, as on the Mac; without it, in twice as far.
    @Test func optionTapZoomsOut() throws {
        let session = try session(.zoom)
        let input = PadCanvasInput(session: session)
        let start = session.viewport.zoom
        let tap = CGPoint(x: 200, y: 150)
        input.began(at: tap, keys: .alternate)
        input.ended(at: tap, keys: .alternate)
        #expect(abs(session.viewport.zoom - start / 2) < 0.0001)
        input.began(at: tap)
        input.ended(at: tap)
        #expect(abs(session.viewport.zoom - start) < 0.0001)
    }

    /// Option let go while sampling ends the sample, as on the Mac: the color stays the one taken, and the rest of the
    /// touch does nothing.
    @Test func lettingOptionGoEndsTheSample() throws {
        for letGo in [false, true] {
            let session = try session(.brush, halves: true)
            session.foregroundColor = .white
            let input = PadCanvasInput(session: session)
            var rings: [Bool] = []
            input.sampleChanged = { rings.append($0 != nil) }
            input.began(at: point(100, 150, in: session), keys: .alternate)
            // Let go with the touch still, or as it moves on.
            if letGo { input.keysChanged([]) }
            input.moved(to: point(300, 150, in: session), keys: [])
            input.ended(at: point(300, 150, in: session), keys: [])
            #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0))
            #expect(rings == [true, false])
            #expect(session.brushStroke == nil)
        }
    }
}
