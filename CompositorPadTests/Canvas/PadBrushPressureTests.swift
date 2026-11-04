import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Apple Pencil's pressure reaching the Brush through the canvas's input, as a tablet pen's does on the Mac. Tests can't
/// make a UITouch, so they hand the input the pressure a touch would have; reading it off a touch takes a real Pencil.
@MainActor struct PadBrushPressureTests {
    /// A 400 × 300 canvas fitted to a view its size, with one opaque layer covering it: all gray, or red on the left half
    /// and blue on the right with a green blemish on the way across; and a large hard red brush, its Size and Opacity
    /// following the pressure as given.
    private func session(_ tool: NavigationTool = .brush, size: Bool = false, opacity: Bool = false, halves: Bool = false) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        if halves {
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
            context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            context.fill(CGRect(x: 110, y: 140, width: 20, height: 20))
        } else {
            context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        session.selectTool(tool)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 1
        session.brushSettings.pressureSize = size
        session.brushSettings.pressureOpacity = opacity
        return session
    }

    /// The active layer's pixels as bytes, top row first, four to a pixel.
    private struct Bitmap: Equatable {
        private let bytes: [UInt8]

        init(_ session: EditorSession) throws {
            let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
            let start = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            bytes = Array(UnsafeBufferPointer(start: start, count: context.bytesPerRow * context.height))
        }

        func byte(_ channel: Int, _ x: Int, _ y: Int) -> Int { Int(bytes[(y * 400 + x) * 4 + channel]) }
        /// How strongly red paint lies on the gray layer at (`x`, `y`), 0–1: it takes the green away.
        func paint(_ x: Int, _ y: Int) -> Double { 1 - Double(byte(1, x, y)) / 128 }
        /// How many rows of column `x` the paint covers.
        func thickness(_ x: Int) -> Int { (0..<300).filter { paint(x, $0) > 0.5 }.count }
        /// How many rows of column `x` the eraser cleared.
        func erased(_ x: Int) -> Int { (0..<300).filter { byte(3, x, $0) < 128 }.count }
        /// How many pixels aren't the plain gray layer any more, and how much paint they hold between them.
        var dot: (pixels: Int, paint: Double) {
            let all = (0..<300).flatMap { y in (0..<400).map { x in paint(x, y) } }.filter { $0 > 0.01 }
            return (all.count, all.reduce(0, +))
        }
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// A left-to-right stroke along y = 150 from x = 50, a sample every 12 pixels at each of `pressures`, lifting on the last.
    private func stroke(_ session: EditorSession, _ pressures: [CGFloat?]) {
        let input = PadCanvasInput(session: session)
        func at(_ index: Int) -> CGPoint { point(50 + 12 * CGFloat(index), 150, in: session) }
        input.began(at: at(0), pressure: pressures[0])
        for index in pressures.indices.dropFirst() { input.moved(to: at(index), pressure: pressures[index]) }
        input.ended(at: at(pressures.count - 1))
    }

    /// 26 samples, x = 50 to 350, all at `pressure`.
    private func stroke(_ session: EditorSession, at pressure: CGFloat?) { stroke(session, Array(repeating: pressure, count: 26)) }

    // MARK: Size and Opacity

    /// With Size on, a light press paints a thinner line than a firm one.
    @Test func aLightPressPaintsThinnerWithSizeOn() throws {
        let light = try session(size: true), firm = try session(size: true)
        stroke(light, at: 0.25)
        stroke(firm, at: 1)
        let thin = try Bitmap(light).thickness(200), full = try Bitmap(firm).thickness(200)
        #expect(abs(full - 40) <= 3, "full pressure, the full size: \(full)")
        #expect(thin >= 8 && thin < 16, "a quarter of the pressure, about a quarter of the size: \(thin)")
    }

    /// Each sample uses its own pressure, so the line thins as the pressure eases.
    @Test func eachSampleUsesItsOwnPressure() throws {
        let session = try session(size: true)
        stroke(session, (0..<26).map { 1 - 0.75 * CGFloat($0) / 25 })
        let bitmap = try Bitmap(session)
        let start = bitmap.thickness(60), middle = bitmap.thickness(200), end = bitmap.thickness(340)
        #expect(start > middle && middle > end, "\(start), \(middle), \(end)")
        #expect(abs(start - 40) <= 4 && end < 16, "\(start), \(end)")
    }

    /// The first sample too: a tap paints a dab the size of its own pressure.
    @Test func aTapPaintsAtItsOwnPressure() throws {
        let session = try session(size: true)
        let input = PadCanvasInput(session: session)
        let tap = point(200, 150, in: session)
        input.began(at: tap, pressure: 0.25)
        input.ended(at: tap)
        let thin = try Bitmap(session).thickness(200)
        #expect(thin >= 8 && thin < 16, "\(thin)")
    }

    /// With Opacity on, a light press paints fainter, and the firmest stays within the brush's Opacity.
    @Test func aLightPressPaintsFainterWithOpacityOnUpToTheSetting() throws {
        for (pressure, expected) in [(CGFloat(1), 0.5), (0.5, 0.25)] {
            let session = try session(opacity: true)
            session.brushSettings.opacity = 0.5
            stroke(session, at: pressure)
            let paint = try Bitmap(session).paint(200, 150)
            #expect(abs(paint - expected) < 0.04, "at \(pressure): \(paint)")
        }
    }

    /// Neither following the pressure, or no pressure to follow, as with a finger: the same pixels as a stroke at full
    /// pressure.
    @Test func neitherFollowingOrAFingerPaintAsAtFullPressure() throws {
        let plain = try session()
        stroke(plain, at: nil)
        let expected = try Bitmap(plain)
        #expect(expected.thickness(200) >= 37)

        let neither = try session()
        stroke(neither, at: 0.2)
        #expect(try Bitmap(neither) == expected)
        let finger = try session(size: true, opacity: true)
        stroke(finger, at: nil)
        #expect(try Bitmap(finger) == expected)
        let firmest = try session(size: true, opacity: true)
        stroke(firmest, at: 1)
        #expect(try Bitmap(firmest) == expected)
    }

    // MARK: The lift

    /// The lift carries no pressure: the stroke ends at the last one, not a full-size blot.
    @Test func theLiftKeepsTheLastPressure() throws {
        let session = try session(size: true)
        let input = PadCanvasInput(session: session)
        input.began(at: point(50, 150, in: session), pressure: 0.25)
        input.moved(to: point(200, 150, in: session), pressure: 0.25)
        input.ended(at: point(350, 150, in: session))
        let bitmap = try Bitmap(session)
        #expect(bitmap.thickness(345) >= 8, "the stroke goes on to where the touch lifted")
        #expect((0..<400).map(bitmap.thickness).max()! < 16)
    }

    /// With Smoothing on, the stretch that catches up with the tip at the lift keeps it too.
    @Test func smoothingsCatchUpKeepsTheLastPressure() throws {
        let session = try session(size: true)
        session.brushSettings.smoothing = 30
        stroke(session, at: 0.25)
        let bitmap = try Bitmap(session)
        #expect(bitmap.thickness(348) >= 8, "the stroke catches up with where the touch lifted")
        #expect((0..<400).map(bitmap.thickness).max()! < 16)
    }

    // MARK: Shift

    /// Shift's straight line from the last stroke paints at the pressure of the touch that drew it, at both ends.
    @Test func shiftsLineCarriesThePressure() throws {
        for (pressure, thin) in [(CGFloat(0.25), true), (1, false)] {
            let session = try session(size: true)
            let input = PadCanvasInput(session: session)
            let start = point(50, 150, in: session), tap = point(300, 150, in: session)
            input.began(at: start, pressure: 0.25)
            input.ended(at: start)
            input.began(at: tap, keys: .shift, pressure: pressure)
            input.ended(at: tap, keys: .shift)
            let bitmap = try Bitmap(session)
            let thickest = (0..<400).map(bitmap.thickness).max()!, middle = bitmap.thickness(175)
            if thin { #expect(middle >= 8 && thickest < 16, "\(middle), \(thickest)") } else { #expect(abs(middle - 40) <= 3, "\(middle)") }
        }
    }

    // MARK: Other tools

    /// The Eraser is a mode of the Brush, so it follows the pressure too, as on the Mac.
    @Test func theEraserFollowsThePressure() throws {
        for (pressure, thin) in [(CGFloat(0.25), true), (1, false)] {
            let session = try session(size: true)
            session.brushMode = .erase
            stroke(session, at: pressure)
            let erased = try Bitmap(session).erased(200)
            if thin { #expect(erased >= 8 && erased < 16, "\(erased)") } else { #expect(abs(erased - 40) <= 3, "\(erased)") }
        }
    }

    /// Only the Brush follows the pressure: the other brush tools paint at full pressure, with Size and Opacity set to
    /// follow it or not, as on the Mac.
    @Test func theOtherBrushToolsIgnoreThePressure() throws {
        let tools: [(NavigationTool, BlurToolMode)] = [(.spotHealing, .blur), (.cloneStamp, .blur), (.blur, .blur), (.blur, .smudge), (.blur, .liquify)]
        for (tool, blurMode) in tools {
            func painted(_ pressure: CGFloat?) throws -> Bitmap {
                let session = try session(tool, size: true, opacity: true, halves: true)
                session.blurMode = blurMode
                session.setCloneSource(CGPoint(x: 100, y: 60))
                stroke(session, at: pressure)
                return try Bitmap(session)
            }
            let untouched = try session(tool, halves: true)
            let full = try painted(nil)
            #expect(full != (try Bitmap(untouched)), "\(tool), \(blurMode) changed nothing")
            #expect(try painted(0.2) == full, "\(tool), \(blurMode)")
        }
    }

    // MARK: A light touch

    /// A single sample at the lightest press, with Size on, still leaves a dot of at least a pixel, wherever it lands.
    @Test func aSingleLightSampleStillLeavesADot() throws {
        for (x, y) in [(CGFloat(200), CGFloat(150)), (200.5, 150.5), (200.25, 150.75)] {
            for pressure in [CGFloat(0), 0.01] {
                let session = try session(size: true)
                let input = PadCanvasInput(session: session)
                let tap = point(x, y, in: session)
                input.began(at: tap, pressure: pressure)
                input.ended(at: tap)
                let dot = try Bitmap(session).dot
                #expect(dot.pixels >= 1 && dot.pixels <= 16, "at (\(x), \(y)), \(pressure): \(dot.pixels) pixels")
                #expect(dot.paint >= 0.5, "at (\(x), \(y)), \(pressure): \(dot.paint) of paint")
            }
        }
    }

    // MARK: From force to pressure

    /// The square root of the force's share of 0.6 of the maximum, as measured on an iPad Air (3rd generation) with the
    /// first Apple Pencil, whose maximum is 4.167: a firm but natural stroke, from about 2.5, paints at the full Size and
    /// Opacity; everyday writing, about 0.35, at well over a third; a light touch, about 0.086, still visibly.
    @Test func forceBecomesPressureFullAtAFirmStroke() throws {
        func pressure(_ force: CGFloat, _ maximum: CGFloat = 4.167, type: UITouch.TouchType = .pencil) -> CGFloat? {
            PadCanvasInput.pressure(type: type, force: force, maximumPossibleForce: maximum)
        }
        #expect(abs(try #require(pressure(0.35)) - 0.3742) < 0.001, "everyday writing")
        #expect(abs(try #require(pressure(0.086)) - 0.1855) < 0.001, "a light touch")
        #expect(abs(try #require(pressure(1)) - 0.6324) < 0.001, "an average touch")
        #expect(try #require(pressure(2.4)) > 0.97 && pressure(2.4)! < 1, "just short of a firm stroke")
        #expect(pressure(0.6 * 4.167) == 1, "a firm stroke, the full size")
        #expect(pressure(2.9) == 1 && pressure(4.167) == 1, "never past the full size")
        #expect(pressure(0) == 0)
        #expect(pressure(-0.1) == 0, "no negative force")
        #expect(abs(try #require(pressure(1.5, 5)) - 0.7071) < 0.001, "a share of whatever maximum the Pencil reports")
        #expect(pressure(1, 0) == nil, "no force reported")
        #expect(pressure(1, type: .direct) == nil, "a finger presses fully")
        #expect(pressure(1, type: .indirectPointer) == nil, "the pointer presses fully")
    }
}
