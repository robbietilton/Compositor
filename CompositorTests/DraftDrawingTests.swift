import CoreGraphics
import CoreImage
import Testing
@testable import Compositor

/// What the canvases draw while the Gradient and Shape tools are dragging, which every platform's canvas shares.
@MainActor struct DraftDrawingTests {
    /// A 300 × 200 canvas with the Shape tool in hand and a blue foreground.
    private func session() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        session.selectTool(.shape)
        session.foregroundColor = PaletteColor(red: 0, green: 0, blue: 1)
        return session
    }

    /// The color at (`x`, `y`) of a 300 × 200 drawing, counted from its top left.
    private func color(at x: Int, _ y: Int, of draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 300 * 200 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Drawn y down, as the canvases draw.
            context.translateBy(x: 0, y: 200)
            context.scaleBy(x: 1, y: -1)
            draw(context)
        }
        let index = (y * 300 + x) * 4
        return Array(pixels[index..<index + 4])
    }

    /// A rectangle being dragged out fills its box in the foreground color, and nothing outside it.
    @Test func aRectangleFillsItsBoxInTheForeground() {
        let session = session()
        session.shapeKind = .rectangle
        session.beginShape(at: CGPoint(x: 40, y: 30))
        session.dragShape(to: CGPoint(x: 140, y: 90), square: false, fromCenter: false)
        let draw: (CGContext) -> Void = { session.drawShapeDraft(scale: 1, center: { $0 }, in: $0) }
        #expect(color(at: 90, 60, of: draw) == [0, 0, 255, 255])
        #expect(color(at: 20, 60, of: draw) == [0, 0, 0, 0])
        #expect(color(at: 90, 120, of: draw) == [0, 0, 0, 0])
    }

    /// The shape's bitmap is just big enough for it, a line's width and a little around.
    @Test func theShapesImageIsJustBigEnough() throws {
        let session = session()
        session.shapeKind = .ellipse
        session.shapeLineWidth = 6
        session.beginShape(at: CGPoint(x: 40, y: 30))
        session.dragShape(to: CGPoint(x: 140, y: 90), square: false, fromCenter: false)
        let renderer = try #require(GPUCanvasRenderer.shared)
        let placement = GPUPlacement(mapping: CGAffineTransform(scaleX: 2, y: 2), scale: 2, renderer: renderer)
        let image = try #require(session.shapeDraftImage(placement: placement))
        // The box at twice the size, grown by the line's 6 pixels at that scale and 4 more.
        #expect(image.extent == CGRect(x: 64, y: 44, width: 232, height: 152))
    }

    /// Shift turns a gradient's line to the nearest 45° step about its other end, keeping its length.
    @Test func aGradientLineTurnsToTheNearestEighth() {
        let flat = GradientEdit.constrained(CGPoint(x: 110, y: 52), around: CGPoint(x: 10, y: 50))
        #expect(abs(flat.y - 50) < 0.0001 && abs(flat.x - (10 + hypot(100, 2))) < 0.0001)
        let diagonal = GradientEdit.constrained(CGPoint(x: 60, y: 54), around: CGPoint(x: 10, y: 10))
        #expect(abs((diagonal.x - 10) - (diagonal.y - 10)) < 0.0001)
    }
}
