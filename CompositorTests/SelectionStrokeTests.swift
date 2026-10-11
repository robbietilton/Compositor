import AppKit
import Testing
@testable import Compositor

@MainActor
struct SelectionStrokeTests {
    /// An opaque white layer filling a `size` × `size` canvas, with a 10 × 10 selection at 5, 5.
    private func session(size: Int = 20) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: size, height: size)
        let context = try BrushRaster.context(width: size, height: size, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "White"))
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 5, y: 5, width: 10, height: 10), transform: nil))
        return session
    }

    /// Brightness of the layer's pixel at x, y (document pixels; the layer fills the canvas).
    private func brightness(_ session: EditorSession, _ x: Int, _ y: Int) throws -> CGFloat {
        let image = try #require(session.activeLayer?.asset?.image)
        // The stored value, without a color conversion that would move the grays.
        var pixel = [Int](repeating: 0, count: 4)
        NSBitmapImageRep(cgImage: image).getPixel(&pixel, atX: x, y: y)
        return CGFloat(pixel[0]) / 255
    }

    @Test func eachLocationPaintsItsSideOfTheOutline() async throws {
        // Along the left edge (x = 5), a 2 px line: which columns turn black.
        for (location, black, white) in [
            (StrokeLocation.inside, [5, 6], [4, 7]),
            (.center, [4, 5], [3, 6]),
            (.outside, [3, 4], [2, 5])
        ] {
            let session = try session()
            session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 0), background: false)
            await session.strokeSelection(StrokeOptions(width: 2, location: location))
            for x in black { #expect(try brightness(session, x, 10) < 0.01, "\(location) \(x)") }
            for x in white { #expect(try brightness(session, x, 10) > 0.99, "\(location) \(x)") }
            // The middle of the selection is never painted, and the selection stays as it was.
            #expect(try brightness(session, 10, 10) > 0.99)
            #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 5, y: 5, width: 10, height: 10))
        }
    }

    @Test func opacityAndUndo() async throws {
        let session = try session()
        let original = session.document
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 0), background: false)
        await session.strokeSelection(StrokeOptions(width: 2, location: .inside, opacity: 0.5))
        let half = try brightness(session, 5, 10)
        #expect(abs(half - 0.5) < 0.05, "\(half)")
        session.undo()
        #expect(session.document == original)
    }

    @Test func aSmallStrokeOnALargeLayerTouchesOnlyItsOwnTiles() throws {
        let session = try session(size: 2048)
        let layer = try #require(session.activeLayer)
        let edit = try session.makeRasterEdit(for: layer, clipsToSelection: false)
        let outline = try #require(session.selection?.path)
        let options = StrokeOptions(width: 2, location: .outside)
        try edit.stroke(options.region(around: outline), keeping: .outside, of: outline,
                        color: CGColor(gray: 0, alpha: 1), opacity: 1)
        // 64 tiles of 256 px cover the layer; a stroke round a 10 px square lies in the first.
        #expect(edit.patches.count == 1)

        // Round a selection almost as large as the layer, only the outer ring of tiles is touched (28, and at most
        // a neighbor of theirs the edge's antialiasing reaches), not the 36 it encloses.
        let large = try session.makeRasterEdit(for: layer, clipsToSelection: false)
        let frame = CGPath(rect: CGRect(x: 100, y: 100, width: 1800, height: 1800), transform: nil)
        try large.stroke(options.region(around: frame), keeping: .outside, of: frame, color: CGColor(gray: 0, alpha: 1), opacity: 1)
        #expect((28...40).contains(large.patches.count))
        #expect(!large.patches.contains { $0.rect.intersects(CGRect(x: 512, y: 512, width: 1024, height: 1024)) })
    }
}