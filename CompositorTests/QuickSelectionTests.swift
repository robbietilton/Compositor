import AppKit
import Testing
@testable import Compositor

@MainActor
struct QuickSelectionTests {
    private func image(width: Int, height: Int, _ color: (Int, Int) -> [UInt8]) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = color(x, y)
                for channel in 0..<4 {
                    bytes[y * context.bytesPerRow + x * 4 + channel] = pixel[channel]
                }
            }
        }
        return try #require(context.makeImage())
    }

    @Test func quickSelectionDoesNotCrossSyntheticSoftEdge() throws {
        let image = try image(width: 200, height: 100) { x, _ in
            x < 120 ? [245, 190, 20, 255] : [255, 255, 255, 255]
        }
        let mask = try #require(QuickSelection.mask(
            in: image,
            points: [CGPoint(x: 80, y: 50)],
            settings: QuickSelectionSettings(diameter: 40)
        ))
        #expect(mask[50 * 200 + 80] > 0)
        #expect(mask[50 * 200 + 160] == 0)
    }

    @Test func quickSelectionSmallDiameterFollowsShading() throws {
        let image = try image(width: 240, height: 80) { x, _ in
            x < 180 ? [UInt8(180 + (x % 35)), 120, 20, 255] : [245, 245, 245, 255]
        }
        let mask = try #require(QuickSelection.mask(
            in: image,
            points: stride(from: 40, through: 160, by: 20).map { CGPoint(x: $0, y: 40) },
            settings: QuickSelectionSettings(diameter: 10)
        ))
        #expect(mask[40 * 240 + 140] > 0)
        #expect(mask[40 * 240 + 220] == 0)
    }

    @Test func quickSelectionCommitsOneHistoryEntryPerDrag() async throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)
        let before = session.history.undoCount
        session.beginQuickSelection(at: CGPoint(x: 20, y: 20), mode: .replace)
        session.extendQuickSelection(to: CGPoint(x: 40, y: 40))
        await session.finishQuickSelection()
        #expect(session.history.undoCount == before + 1)
    }
}
