import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct CanvasRotationTests {
    /// A 5 × 3 canvas filled by one layer whose every pixel is its own color, so any misplaced or blended pixel shows.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 5, height: 3)
        let context = try BrushRaster.context(width: 5, height: 3, mask: false)
        for y in 0..<3 {
            for x in 0..<5 {
                context.setFillColor(CGColor(srgbRed: CGFloat(x) / 4, green: CGFloat(y) / 2, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Pixels"))
        return session
    }

    private func render(_ session: EditorSession) async throws -> NSBitmapImageRep {
        let snapshot = try #require(session.projectSnapshot())
        let data = try await ImageExporter.shared.pngData(snapshot)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return NSBitmapImageRep(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func bytes(_ image: CGImage?) throws -> Data {
        let image = try #require(image)
        return try #require(image.dataProvider?.data) as Data
    }

    @Test func quarterAndHalfTurnsMovePixelsExactly() async throws {
        let original = try await render(try session())
        for rotation in CanvasRotation.allCases {
            let session = try session()
            await session.rotateCanvas(rotation)
            let document = try #require(session.document)
            #expect(document.width == (rotation.swapsSides ? 3 : 5))
            #expect(document.height == (rotation.swapsSides ? 5 : 3))
            // The pixels were turned, so the layer stays upright and unscaled: nothing is resampled when drawn.
            let layer = try #require(document.layers.first)
            #expect(layer.transform.rotation == 0)
            #expect(layer.transform.origin == .zero)
            #expect(layer.transform.size == document.size)
            #expect(layer.asset?.image.width == document.width)
            let turned = try await render(session)
            let map = rotation.map(width: 5, height: 3)
            for y in 0..<3 {
                for x in 0..<5 {
                    // The pixel's middle, carried by the turn, lands in the middle of its new pixel.
                    let middle = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(map)
                    let expected = try #require(original.colorAt(x: x, y: y))
                    let actual = try #require(turned.colorAt(x: Int(middle.x), y: Int(middle.y)))
                    #expect(abs(actual.redComponent - expected.redComponent) < 0.01, "\(rotation) \(x),\(y)")
                    #expect(abs(actual.greenComponent - expected.greenComponent) < 0.01, "\(rotation) \(x),\(y)")
                    #expect(actual.alphaComponent == 1, "\(rotation) \(x),\(y)")
                }
            }
        }
    }

    @Test func fullTurnAndUndoGiveBackTheOriginal() async throws {
        let session = try session()
        let original = try #require(session.document)
        for _ in 0..<4 { await session.rotateCanvas(.clockwise) }
        #expect(session.document?.layers.map(\.transform) == original.layers.map(\.transform))
        #expect(try bytes(session.document?.layers.first?.asset?.image) == bytes(original.layers.first?.asset?.image))
        await session.rotateCanvas(.counterclockwise)
        await session.rotateCanvas(.clockwise)
        #expect(try bytes(session.document?.layers.first?.asset?.image) == bytes(original.layers.first?.asset?.image))
        await session.rotateCanvas(.halfTurn)
        session.undo()
        #expect(try bytes(session.document?.layers.first?.asset?.image) == bytes(original.layers.first?.asset?.image))
        #expect(session.document?.width == 5)
        for _ in 0..<6 { session.undo() }
        #expect(session.document == original)
    }

    @Test func selectionGuidesAndMasksTurnWithTheCanvas() async throws {
        let session = try session()
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 2, height: 1), transform: nil))
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 1))
        session.addGuide(CanvasGuide(id: UUID(), axis: .horizontal, position: 1))
        // A mask hiding the layer's left column.
        let mask = try BrushRaster.context(width: 5, height: 3, mask: true)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 5, height: 3))
        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 1, height: 3))
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: try #require(mask.makeImage())))
        await session.rotateCanvas(.clockwise)
        #expect(session.document?.selection?.path.boundingBoxOfPath == CGRect(x: 2, y: 0, width: 1, height: 2))
        // A vertical guide at x = 1 becomes a horizontal one at y = 1; a horizontal one at y = 1 a vertical at 3 − 1.
        #expect(session.document?.guides.first { $0.axis == .horizontal }?.position == 1)
        #expect(session.document?.guides.first { $0.axis == .vertical }?.position == 2)
        // The hidden column is now the top row.
        let turned = try await render(session)
        #expect(try #require(turned.colorAt(x: 1, y: 0)).alphaComponent == 0)
        #expect(try #require(turned.colorAt(x: 1, y: 1)).alphaComponent == 1)
    }

    @Test func placementsFollowTheTurn() {
        let map = CanvasRotation.clockwise.map(width: 5, height: 3)
        let placement = LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 2, height: 1), flipX: true)
        // Turned pixels: sides swap, the flip moves to the other axis, the angle stays.
        #expect(placement.placingTurnedPixels(.clockwise, by: map)
            == LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 1, height: 2), flipY: true))
        // Live text and shapes turn by their angle instead.
        #expect(placement.turned(90, by: map)
            == LayerTransform(origin: CGPoint(x: 0.5, y: 1.5), size: CGSize(width: 2, height: 1), rotation: 90, flipX: true))
    }
}