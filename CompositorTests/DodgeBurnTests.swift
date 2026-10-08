import AppKit
import Testing
@testable import Compositor

@MainActor
struct DodgeBurnTests {
    /// A 120 × 40 layer: dark (0.2) on the left third, middle gray (0.5) in the middle, light (0.8) on the right, with
    /// its alpha at `alpha`.
    private func session(alpha: CGFloat = 1) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 40)
        let context = try BrushRaster.context(width: 120, height: 40, mask: false)
        for (index, gray) in [0.2, 0.5, 0.8].enumerated() {
            context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: alpha))
            context.fill(CGRect(x: index * 40, y: 0, width: 40, height: 40))
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Grays"))
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 30, hardness: 1)
        return session
    }

    /// The layer's straight color and alpha at a pixel, read without color conversion.
    private func pixel(_ session: EditorSession, _ x: Int, _ y: Int = 20) throws -> (value: Int, alpha: Int) {
        let image = try #require(session.activeLayer?.asset?.image)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return (pixel[3] == 0 ? 0 : pixel[0] * 255 / pixel[3], pixel[3])
    }

    /// One stroke from the left edge of the layer to the right, through its middle.
    private func stroke(_ session: EditorSession, from: CGFloat = 5, to: CGFloat = 115) {
        session.beginBrush(at: CGPoint(x: from, y: 20))
        session.continueBrush(at: CGPoint(x: to, y: 20))
        session.finishBrushImmediately()
    }

    @Test func dodgeLightensAndBurnDarkensMostInTheirRange() throws {
        for range in ToneRange.allCases {
            for lightens in [true, false] {
                let session = try session()
                session.brushMode = lightens ? .dodge : .burn
                session.toneRange = range
                session.toneExposure = 1
                let before = try [20, 60, 100].map { try pixel(session, $0).value }
                stroke(session)
                #expect(session.brushError == nil)
                let after = try [20, 60, 100].map { try pixel(session, $0).value }
                let moved = zip(before, after).map { abs($1 - $0) }
                for (old, new) in zip(before, after) { #expect(lightens ? new >= old : new <= old) }
                // Each range moves its own tones the most.
                let most = moved.firstIndex(of: moved.max()!)!
                #expect(most == [ToneRange.shadows: 0, .midtones: 1, .highlights: 2][range], "\(range) \(lightens) \(moved)")
                #expect(session.history.undoName == (lightens ? "Dodge" : "Burn"))
            }
        }
    }

    @Test func exposureAndOpacityScaleItAndZeroChangesNothing() throws {
        var moves: [Int] = []
        for (exposure, opacity) in [(1.0, 1.0), (0.5, 1.0), (1.0, 0.5), (0.25, 1.0)] {
            let session = try session()
            session.brushMode = .dodge
            session.toneExposure = exposure
            session.brushSettings.opacity = opacity
            stroke(session)
            moves.append(try pixel(session, 60).value - 128)
        }
        #expect(moves[0] > moves[1] && moves[1] > moves[3] && moves[3] > 0)
        #expect(abs(moves[1] - moves[2]) <= 1, "half exposure and half opacity cap the stroke alike")

        let session = try session()
        session.brushMode = .burn
        session.toneExposure = 0
        let count = session.history.undoCount
        stroke(session)
        #expect(session.history.undoCount == count)
    }

    @Test func aStrokeThatChangesNothingLeavesNoUndoStep() throws {
        let session = EditorSession()
        session.createDocument(width: 60, height: 60)
        let context = try BrushRaster.context(width: 60, height: 60, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "White"))
        session.selectTool(.brush)
        session.brushMode = .dodge
        session.toneRange = .highlights
        session.toneExposure = 1
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 10, y: 30))
        session.continueBrush(at: CGPoint(x: 50, y: 30))
        session.finishBrushImmediately()
        #expect(session.history.undoCount == count, "white can't get any lighter")
    }

    @Test func alphaStaysAndTransparentPixelsStayTransparent() throws {
        let session = try session(alpha: 0.5)
        session.brushMode = .dodge
        session.toneExposure = 1
        let before = try pixel(session, 60)
        stroke(session)
        let after = try pixel(session, 60)
        #expect(after.value > before.value + 20)
        #expect(after.alpha == before.alpha)

        // A layer with a transparent hole: Burn keeps it clear.
        let clear = try self.session()
        let layerID = try #require(clear.activeLayerID)
        clear.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 50, y: 0, width: 20, height: 40), transform: nil))
        clear.brushMode = .erase
        stroke(clear)
        clear.document?.selection = nil
        clear.brushMode = .burn
        clear.toneExposure = 1
        stroke(clear)
        #expect(clear.activeLayerID == layerID)
        #expect(try pixel(clear, 60).alpha == 0)
    }

    @Test func theSelectionLimitsItAndEachStrokeUndoesOnItsOwn() throws {
        let session = try session()
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 80, height: 40), transform: nil))
        session.brushMode = .dodge
        session.toneExposure = 0.5
        let original = try (pixel(session, 60).value, pixel(session, 100).value)
        stroke(session)
        let first = try (pixel(session, 60).value, pixel(session, 100).value)
        #expect(first.0 > original.0 && first.1 == original.1, "outside the selection nothing moves")
        stroke(session)
        let second = try pixel(session, 60).value
        #expect(second > first.0, "a second stroke builds on the first")
        session.undo()
        #expect(try pixel(session, 60).value == first.0)
        session.undo()
        #expect(try pixel(session, 60).value == original.0)
        session.redo()
        #expect(try pixel(session, 60).value == first.0)
    }

    /// The result is ordinary layer pixels: the export shows them as the layer holds them.
    @Test func theExportShowsTheResult() async throws {
        let session = try session()
        session.brushMode = .dodge
        session.toneExposure = 1
        stroke(session)
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        var pixel = [Int](repeating: 0, count: 4)
        NSBitmapImageRep(cgImage: exported).getPixel(&pixel, atX: 60, y: 20)
        #expect(abs(pixel[0] - (try self.pixel(session, 60).value)) <= 1 && pixel[0] > 150)
    }

    @Test func aMaskTargetIsRefusedAndADisplayedMaskDoesNotClip() throws {
        let session = try session()
        session.addLayerMask(revealing: false)
        #expect(session.activeLayer?.mask != nil && session.isMaskSelected)
        session.brushMode = .dodge
        let count = session.history.undoCount
        stroke(session)
        #expect(session.brushError?.contains("mask") == true && session.history.undoCount == count)
        session.brushError = nil
        // The layer's pixels targeted, under a mask that hides everything: they still change.
        session.isMaskSelected = false
        session.toneExposure = 1
        let before = try pixel(session, 60).value
        stroke(session)
        #expect(try pixel(session, 60).value > before)
    }
}