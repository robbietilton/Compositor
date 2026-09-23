import AppKit
import Testing
@testable import Compositor

@MainActor
struct PaintBucketTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 12, height: 8, emptyLayer: true)
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        session.selectTool(.gradient)
        session.changeFillToolMode(.bucket)
        return session
    }
    private func pixel(_ session: EditorSession, x: Int, y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }
    private func wall(_ session: EditorSession) async {
        session.applySelection(CGPath(rect: CGRect(x: 5, y: 0, width: 2, height: 8), transform: nil), mode: .replace, name: "Wall")
        await session.fillSelection(with: .background)
        session.deselect()
    }

    @Test func contiguousRegionLeavesDisconnectedPixelsAndUndoRestores() async throws {
        let session = makeSession()
        await wall(session)
        let before = session.document
        let count = session.history.undoCount
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(session.brushError == nil)
        #expect(try await pixel(session, x: 1, y: 2) == [255, 0, 0, 255])
        #expect(try await pixel(session, x: 6, y: 2) == [255, 255, 255, 255])
        #expect(try await pixel(session, x: 10, y: 2)[3] == 0)
        #expect(session.selection == nil && session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(try await pixel(session, x: 1, y: 2) == [255, 0, 0, 255])
    }

    @Test func noncontiguousFillAndToleranceUseSharedMatcher() async throws {
        let session = makeSession()
        await wall(session)
        session.bucketSettings.contiguous = false
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(try await pixel(session, x: 10, y: 2) == [255, 0, 0, 255])
        session.bucketSettings.tolerance = 255
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 1), background: false)
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(try await pixel(session, x: 6, y: 2) == [0, 0, 255, 255])
    }

    @Test func respectsSelectionAndPreservesItsOutline() async throws {
        let session = makeSession()
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 4, height: 8), transform: nil), mode: .replace, name: "Select")
        let selection = session.selection
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(session.selection == selection)
        #expect(try await pixel(session, x: 1, y: 2) == [255, 0, 0, 255])
        #expect(try await pixel(session, x: 6, y: 2)[3] == 0)
        let before = session.document
        let count = session.history.undoCount
        await session.paintBucket(at: CGPoint(x: 8, y: 2))
        #expect(session.document == before && session.history.undoCount == count)
    }

    @Test func samplesVisibleLayersButOnlyPaintsActiveBlankLayer() async throws {
        let session = makeSession()
        await wall(session)
        let wallLayer = try #require(session.activeLayer)
        session.addBlankLayer()
        session.bucketSettings.sampleAllLayers = true
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(session.document?.layers[0] == wallLayer)
        #expect(try await pixel(session, x: 1, y: 2) == [255, 0, 0, 255])
        #expect(try await pixel(session, x: 10, y: 2)[3] == 0)
    }

    @Test func opacityAndFeatherAreAppliedOnlyOnce() async throws {
        let session = makeSession()
        session.gradientSettings.opacity = 0.5
        await session.paintBucket(at: CGPoint(x: 1, y: 2))
        #expect(try await pixel(session, x: 1, y: 2)[3] >= 127)
        #expect(try await pixel(session, x: 1, y: 2)[3] <= 128)
        session.undo()
        session.gradientSettings.opacity = 1
        session.document?.selection = DocumentSelection(path: CGPath(rect:
            CGRect(x: 2, y: 0, width: 6, height: 8), transform: nil), feather: 2)
        let coverage = try #require(session.selection).coverage(width: 12, height: 8)
        let gray = try BrushRaster.context(width: 12, height: 8, mask: true)
        BrushRaster.draw(coverage, in: CGRect(x: 0, y: 0, width: 12, height: 8), mask: true, context: gray)
        let expected = Int(try #require(gray.data).assumingMemoryBound(to: UInt8.self)[4 * gray.bytesPerRow + 2])
        await session.paintBucket(at: CGPoint(x: 4, y: 4))
        #expect(abs(try await pixel(session, x: 2, y: 4)[3] - expected) <= 2)
    }

    @Test func transformedLayerUsesDocumentCoordinates() async throws {
        let session = makeSession()
        await wall(session)
        session.document?.layers[0].transform.origin.x += 2
        await session.paintBucket(at: CGPoint(x: 8, y: 3))
        #expect(try await pixel(session, x: 8, y: 3) == [255, 0, 0, 255])
        #expect(try await pixel(session, x: 5, y: 3)[3] == 0)
    }

    @Test func rejectsInvalidClicksEmptySelectionsAndHiddenLayers() async throws {
        let session = makeSession()
        let before = session.document
        for point in [CGPoint(x: -1, y: 1), CGPoint(x: 12, y: 1), CGPoint(x: CGFloat.nan, y: 1)] {
            await session.paintBucket(at: point)
            #expect(session.document == before)
        }
        session.document?.selection = DocumentSelection(path: CGMutablePath())
        #expect(!session.canPaintBucket)
        session.document?.selection = nil
        session.document?.layers[0].isVisible = false
        #expect(!session.canPaintBucket)
    }

    @Test func modeSwitchKeepsPendingGradientAndExistingSelection() {
        let session = makeSession()
        session.cycleToolMode()
        #expect(session.fillToolMode == .gradient)
        session.beginGradient(at: CGPoint(x: 1, y: 1))
        session.changeFillToolMode(.bucket)
        #expect(session.fillToolMode == .gradient && session.gradientEdit != nil)
        session.cancelGradient()
        session.cycleToolMode()
        #expect(session.fillToolMode == .bucket)
    }
}
