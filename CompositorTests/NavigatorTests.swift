import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct NavigatorTests {
    @Test func documentFitsTheBoxCentred() {
        let geometry = NavigatorGeometry(documentSize: CGSize(width: 400, height: 200), box: CGSize(width: 200, height: 200))
        #expect(geometry.imageRect == CGRect(x: 0, y: 50, width: 200, height: 100))
        #expect(geometry.thumbnailRect(for: CGRect(x: 100, y: 50, width: 200, height: 100)) == CGRect(x: 50, y: 75, width: 100, height: 50))
        #expect(geometry.documentPoint(for: CGPoint(x: 100, y: 100)) == CGPoint(x: 200, y: 100))
        // Points outside the picture land on the document's edge.
        #expect(geometry.documentPoint(for: CGPoint(x: -20, y: 199)) == CGPoint(x: 0, y: 200))
        #expect(NavigatorGeometry(documentSize: .zero, box: CGSize(width: 10, height: 10)).imageRect == .zero)
    }

    /// A 400 × 300 document in an 800 × 600 view at 1× backing.
    private func viewport() -> CanvasViewport {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 1, documentSize: CGSize(width: 400, height: 300))
        return viewport
    }

    @Test func visibleRectFollowsZoomAndPan() {
        let size = CGSize(width: 400, height: 300)
        var viewport = viewport()
        viewport.setZoom(4, anchoredAt: viewport.center, documentSize: size)
        let visible = viewport.visibleDocumentRect(documentSize: size)
        #expect(abs(visible.width - 200) < 0.001 && abs(visible.height - 150) < 0.001, "800 × 600 points at 4× show 200 × 150 pixels")
        #expect(abs(visible.midX - 200) < 0.001 && abs(visible.midY - 150) < 0.001)
    }

    @Test func centringKeepsZoomAndStopsFollowingFit() {
        let size = CGSize(width: 400, height: 300)
        var viewport = viewport() // still following Fit, at the fitted zoom (1.68)
        let zoom = viewport.zoom
        viewport.centerView(on: CGPoint(x: 50, y: 60), documentSize: size)
        let visible = viewport.visibleDocumentRect(documentSize: size)
        #expect(abs(visible.midX - 50) < 0.001 && abs(visible.midY - 60) < 0.001)
        #expect(viewport.zoom == zoom)
        // A window resize afterwards keeps the view where the person put it. Still following Fit, it would re-fit
        // to about 2.01 here.
        viewport.resize(to: CGSize(width: 1000, height: 700), backingScale: 1, documentSize: size)
        #expect(viewport.zoom == zoom)
    }

    private func paint(_ width: Int, _ height: Int) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Red")
    }

    private func rgba(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    @Test func pictureFitsTheLongerSideAndShowsTheComposite() throws {
        let session = EditorSession()
        #expect(session.navigatorImage(maxSide: 100) == nil, "nothing to draw without a document")
        session.createDocument(width: 400, height: 200)
        session.document?.layers.append(ImageLayer(asset: try paint(200, 200), origin: .zero))
        let picture = try #require(session.navigatorImage(maxSide: 100))
        #expect(picture.width == 100 && picture.height == 50)
        #expect(try rgba(picture, 25, 25) == [255, 0, 0, 255])
        #expect(try rgba(picture, 75, 25)[3] == 0, "the empty half stays transparent")
        // Adjustment layers apply, as on the canvas.
        let red = try #require(session.document?.layers.last?.id)
        session.selectLayers([red], primary: red)
        session.addAdjustment(.invert)
        let inverted = try #require(session.navigatorImage(maxSide: 100))
        #expect(try rgba(inverted, 25, 25) == [0, 255, 255, 255])
    }

    @Test func smallDocumentsAreNotEnlarged() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let picture = try #require(session.navigatorImage(maxSide: 900))
        #expect(picture.width == 40 && picture.height == 30)
    }

    @Test func heightStaysInRangeAndSliderIsLogarithmic() {
        #expect(NavigatorPanel.clampedHeight(20) == 90 && NavigatorPanel.clampedHeight(999) == 420)
        #expect(NavigatorPanel.clampedHeight(200) == 200)
        #expect(abs(NavigatorPanel.zoom(forSlider: NavigatorPanel.slider(forZoom: 0.25)) - 0.25) < 0.0001)
        #expect(abs(NavigatorPanel.slider(forZoom: 2) - 1) < 0.0001, "the slider moves in doublings: 2× is one step past 100%")
        #expect(NavigatorPanel.zoom(forSlider: -100) == 0.01 && NavigatorPanel.zoom(forSlider: 100) == 32)
    }

    @Test func panelLaysOutWithAndWithoutADocument() {
        let session = EditorSession()
        // Its own defaults, so what the person set in the app (collapsed, say) can't change the result.
        let defaults = UserDefaults(suiteName: "NavigatorTests-\(UUID().uuidString)")!
        let empty = NSHostingView(rootView: NavigatorPanel(session: session).frame(width: 252).defaultAppStorage(defaults))
        #expect(empty.fittingSize.width == 252)
        session.createDocument(width: 400, height: 300)
        let full = NSHostingView(rootView: NavigatorPanel(session: session).frame(width: 252).defaultAppStorage(defaults))
        #expect(full.fittingSize.height > 160, "the header, the 160 pt picture and the zoom row")
    }

    /// Past the largest surface Compositor allocates (200 megapixels). Drawn at full size, the Invert surface can't be
    /// made and the picture comes out empty; drawn at the picture's size it is cheap.
    @Test func hugeDocumentsWithAdjustmentsStillShow() throws {
        let session = EditorSession()
        session.createDocument(width: 20_000, height: 12_000)
        var layer = ImageLayer(asset: try paint(200, 120), origin: .zero)
        layer.transform.size = CGSize(width: 20_000, height: 12_000)
        session.document?.layers.append(layer)
        session.selectLayers([layer.id], primary: layer.id)
        session.addAdjustment(.invert)
        let picture = try #require(session.navigatorImage(maxSide: 100))
        #expect(picture.width == 100 && picture.height == 60)
        #expect(try rgba(picture, 50, 30) == [0, 255, 255, 255])
    }

    /// A blur measured in document pixels shrinks with the picture, so it looks as it does on the canvas.
    @Test func blursShrinkWithThePicture() throws {
        let session = EditorSession()
        session.createDocument(width: 2000, height: 2000)
        var layer = ImageLayer(asset: try paint(100, 200), origin: .zero)
        layer.transform.size = CGSize(width: 1000, height: 2000)
        session.document?.layers.append(layer)
        session.selectLayers([layer.id], primary: layer.id)
        session.addAdjustment(.gaussianBlur)
        let blur = try #require(session.document?.layers.lastIndex { $0.adjustment != nil })
        session.document?.layers[blur].adjustment?.blurRadius = 100
        let picture = try #require(session.navigatorImage(maxSide: 100))
        // 5 blur radii from every edge at the picture's scale: solid red. With the radius left at 100 it would be
        // half blended with the empty half.
        #expect(try rgba(picture, 25, 50)[3] >= 250)
    }

    @Test func selectionChangesDoNotRedrawThePicture() throws {
        var document = CanvasDocument(width: 100, height: 100, layers: [ImageLayer(asset: try paint(10, 10), origin: .zero)])
        let key = NavigatorPanel.RenderKey(document: document, revision: 0, expanded: true)
        document.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 5, height: 5), transform: nil),
                                               antialiased: true, feather: 0)
        #expect(NavigatorPanel.RenderKey(document: document, revision: 0, expanded: true) == key)
        document.layers[0].isVisible = false
        #expect(NavigatorPanel.RenderKey(document: document, revision: 0, expanded: true) != key)
    }

    /// The picture gives way so the Layers panel keeps its room, however short the window.
    @Test func pictureLeavesRoomForLayers() {
        #expect(NavigatorPanel.pictureHeight(160, column: .infinity) == 160)
        #expect(NavigatorPanel.pictureHeight(420, column: 500) == 500 - NavigatorPanel.reservedHeight)
        #expect(NavigatorPanel.pictureHeight(300, column: 200) == 90, "never smaller than the shortest height")
        #expect(NavigatorPanel.pictureHeight(999, column: .infinity) == 420)
    }
}
