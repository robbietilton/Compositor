import Testing
import CoreGraphics
@testable import Compositor

@MainActor
struct CompositorTests {
    let document = CGSize(width: 1920, height: 1080)

    @Test func dimensionValidation() {
        #expect(CanvasDocument.validDimension("0") == nil)
        #expect(CanvasDocument.validDimension("-1") == nil)
        #expect(CanvasDocument.validDimension("1.5") == nil)
        #expect(CanvasDocument.validDimension("30001") == nil)
        #expect(CanvasDocument.validDimension("9999999999999999999999") == nil)
        #expect(CanvasDocument.validDimension(" 1920 ") == 1920)
        #expect(CanvasDocument.validDimension("30000") == 30000)
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func actualPixelsAndRoundTrip(backing: CGFloat) {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 800, height: 600), backingScale: backing, documentSize: nil)
        for zoom in [CGFloat(0.25), 1, 3.75] {
            viewport.setZoom(zoom, anchoredAt: viewport.center, documentSize: document)
            viewport.translate(by: CGSize(width: 73.5, height: -44.25))
            let pixel = CGPoint(x: 183.25, y: 837.5)
            let viewPoint = viewport.viewPoint(from: pixel, documentSize: document)
            let result = viewport.documentPoint(from: viewPoint, documentSize: document)
            #expect(abs(result.x - pixel.x) < 0.000001)
            #expect(abs(result.y - pixel.y) < 0.000001)
            #expect(abs(viewport.documentRect(document).width * backing - document.width * zoom) < 0.000001)
        }
    }

    @Test func zoomKeepsCursorPixelFixed() {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 1000, height: 700), backingScale: 2, documentSize: document)
        let anchor = CGPoint(x: 157, y: 221)
        let before = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.setZoom(4, anchoredAt: anchor, documentSize: document)
        let after = viewport.documentPoint(from: anchor, documentSize: document)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
    }

    @Test func keyboardZoomKeepsPannedViewportCenterFixed() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 1, documentSize: nil)
        session.createDocument(width: 3000, height: 2000)
        session.zoom(to: 1)
        session.viewport.translate(by: CGSize(width: -620, height: 185))

        let center = session.viewport.center
        let canvas = CGSize(width: 3000, height: 2000)
        let before = session.viewport.documentPoint(from: center, documentSize: canvas)
        session.zoomKeyboard(by: 1)
        let after = session.viewport.documentPoint(from: center, documentSize: canvas)

        #expect(session.viewport.zoom == 1.25)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
        #expect(abs(session.viewport.viewPoint(from: after, documentSize: canvas).x - center.x) < 0.000001)
        #expect(abs(session.viewport.viewPoint(from: after, documentSize: canvas).y - center.y) < 0.000001)
    }

    @Test func keyboardZoomUsesStableStopsAndClampsAtTheEnds() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 1, documentSize: nil)
        session.createDocument(width: 3000, height: 2000)
        session.zoom(to: 0.5)

        session.zoomKeyboard(by: 1)
        #expect(abs(session.viewport.zoom - CGFloat(2.0 / 3.0)) < 0.000001)
        session.zoomKeyboard(by: 1)
        #expect(session.viewport.zoom == 1)
        session.zoomKeyboard(by: 1)
        #expect(session.viewport.zoom == 1.25)

        session.zoom(to: CanvasViewport.keyboardZoomLevels.first!)
        session.zoomKeyboard(by: -1)
        #expect(session.viewport.zoom == CanvasViewport.keyboardZoomLevels.first!)
        session.zoom(to: CanvasViewport.keyboardZoomLevels.last!)
        session.zoomKeyboard(by: 1)
        #expect(session.viewport.zoom == CanvasViewport.keyboardZoomLevels.last!)
    }

    @Test func keyboardZoomRoundTripDoesNotDriftAfterTenSteps() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1200, height: 900), backingScale: 2, documentSize: nil)
        session.createDocument(width: 4000, height: 3000)
        session.zoom(to: 0.5)
        session.viewport.translate(by: CGSize(width: -430, height: 275))

        let center = session.viewport.center
        let canvas = CGSize(width: 4000, height: 3000)
        let before = session.viewport.documentPoint(from: center, documentSize: canvas)
        for _ in 0..<10 { session.zoomKeyboard(by: 1) }
        for _ in 0..<10 { session.zoomKeyboard(by: -1) }
        let after = session.viewport.documentPoint(from: center, documentSize: canvas)

        #expect(session.viewport.zoom == 0.5)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
    }

    @Test func keyboardZoomKeepsSmallCanvasCentered() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1200, height: 900), backingScale: 1, documentSize: nil)
        session.createDocument(width: 200, height: 100)
        session.zoom(to: 0.5)

        let center = session.viewport.center
        let canvas = CGSize(width: 200, height: 100)
        let before = session.viewport.documentPoint(from: center, documentSize: canvas)
        session.zoomKeyboard(by: 1)
        let after = session.viewport.documentPoint(from: center, documentSize: canvas)

        #expect(abs(session.viewport.zoom - CGFloat(2.0 / 3.0)) < 0.000001)
        #expect(abs(before.x - 100) < 0.000001)
        #expect(abs(before.y - 50) < 0.000001)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
    }

    @Test func keyboardZoomFromFitUsesNextStopAndLeavesFitMode() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 1, documentSize: nil)
        session.createDocument(width: 1500, height: 1000)
        session.fit()

        let center = session.viewport.center
        let canvas = CGSize(width: 1500, height: 1000)
        let before = session.viewport.documentPoint(from: center, documentSize: canvas)
        session.zoomKeyboard(by: 1)
        let after = session.viewport.documentPoint(from: center, documentSize: canvas)

        #expect(abs(session.viewport.zoom - CGFloat(2.0 / 3.0)) < 0.000001)
        #expect(!session.viewport.followsFit)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
    }

    @Test func fitAndResizeModes() {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: document)
        let rect = viewport.documentRect(document)
        #expect(rect.width <= 704.000001)
        #expect(rect.height <= 504.000001)
        #expect(rect.midX == 400)
        #expect(rect.midY == 300)
        viewport.translate(by: CGSize(width: 60, height: -35))
        let before = viewport.documentPoint(from: viewport.center, documentSize: document)
        let zoom = viewport.zoom
        viewport.resize(to: CGSize(width: 1200, height: 800), backingScale: 1, documentSize: document)
        let after = viewport.documentPoint(from: viewport.center, documentSize: document)
        #expect(viewport.zoom == zoom)
        #expect(abs(before.x - after.x) < 0.000001)
        #expect(abs(before.y - after.y) < 0.000001)
        viewport.fit(documentSize: document)
        #expect(viewport.pan == .zero)
        #expect(viewport.followsFit)
    }

    /// A canvas that's opened or imported fits the window but stops at 100%, so a small image shows at its real size;
    /// View › Fit (⌘0) still fills the window, and a window resize keeps whichever fit it was.
    @Test func openingStopsAtActualPixelsButFitFillsTheWindow() {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 2, documentSize: nil)
        let small = CGSize(width: 400, height: 300), large = CGSize(width: 6000, height: 4000)
        viewport.fit(documentSize: small)
        #expect(viewport.zoom == 1)
        viewport.resize(to: CGSize(width: 1200, height: 900), backingScale: 2, documentSize: small)
        #expect(viewport.zoom == 1)
        viewport.fit(documentSize: small, enlarging: true)
        #expect(viewport.zoom > 1)
        viewport.resize(to: CGSize(width: 1400, height: 1000), backingScale: 2, documentSize: small)
        #expect(viewport.zoom > 1)
        viewport.fit(documentSize: large)
        #expect(viewport.zoom < 1, "a large image still fits")
    }

    /// Image Size keeps the zoom, so the change shows on screen, rather than fitting the window again.
    @Test func imageSizeKeepsTheZoom() async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 400, emptyLayer: true)
        let zoom = session.viewport.zoom
        let resized = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
                                                           to: ImageSizeOptions(width: 300, height: 200, resolution: 72))
        session.applyImageSize(resized)
        #expect(session.document?.size == CGSize(width: 300, height: 200))
        #expect(session.viewport.zoom == zoom)
        #expect(session.viewport.pan == .zero)
    }

    /// Canvas Size keeps the zoom too, so added or trimmed canvas shows as such.
    @Test func canvasSizeKeepsTheZoom() async throws {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 1000, height: 800), backingScale: 2, documentSize: nil)
        session.createDocument(width: 600, height: 400, emptyLayer: true)
        let zoom = session.viewport.zoom
        let resized = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
                                                            to: CanvasSizeOptions(width: 300, height: 200))
        session.applyDocumentSize(resized, actionName: "Canvas Size", keepingZoom: true)
        #expect(session.document?.size == CGSize(width: 300, height: 200))
        #expect(session.viewport.zoom == zoom)
    }

    @Test func limitsAndNewDocumentReset() {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: nil)
        session.createDocument(width: 1920, height: 1080)
        session.zoom(to: 1000)
        #expect(session.viewport.zoom == CanvasViewport.zoomRange.upperBound)
        session.zoom(to: 0)
        #expect(session.viewport.zoom == CanvasViewport.zoomRange.lowerBound)
        session.viewport.translate(by: CGSize(width: 999, height: 888))
        session.createDocument(width: 400, height: 300)
        #expect(session.viewport.followsFit)
        #expect(session.viewport.pan == .zero)
        #expect(session.document?.width == 400)
        session.createDocument(width: 0, height: 200)
        #expect(session.document?.width == 400)
    }
}
