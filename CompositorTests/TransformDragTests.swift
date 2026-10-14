import CoreGraphics
import Testing
@testable import Compositor

/// The Move tool's drags, which the Mac's canvas and the iPad's share: a press picks a handle or a layer, and each step
/// moves, resizes, turns or distorts it.
@MainActor struct TransformDragTests {
    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// A 400 × 300 canvas with layer A, 100 × 80 at (50, 40), and above it B, 60 × 60 at (270, 160), which is active.
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let a = try image(100, 80), b = try image(60, 60)
        session.insert(ImportedImage(image: a, thumbnail: a, name: "A"), centeredAt: CGPoint(x: 100, y: 80))
        session.insert(ImportedImage(image: b, thumbnail: b, name: "B"), centeredAt: CGPoint(x: 300, y: 190))
        session.selectTool(.move)
        return session
    }

    private func layer(_ name: String, in session: EditorSession) throws -> ImageLayer {
        try #require(session.document?.layers.first { $0.name == name })
    }

    /// With Auto Select on, a press on another layer picks it, and the drag moves it, here without snapping.
    @Test func aPressOnALayerPicksItAndTheDragMovesIt() throws {
        let session = try session()
        // Command turns Auto Select the other way while held, whichever way it's set.
        let drag = try #require(session.beginTransformDrag(at: CGPoint(x: 100, y: 80), handle: nil,
                                                           command: !session.transformAutoSelect))
        #expect(session.activeLayer?.name == "A")
        session.dragTransform(drag, to: CGPoint(x: 130, y: 95), control: true)
        session.commitTransform()
        #expect(try layer("A", in: session).origin == CGPoint(x: 80, y: 55))
    }

    /// A corner handle resizes from the opposite corner, which stays put.
    @Test func aCornerHandleResizesFromTheOppositeCorner() throws {
        let session = try session()
        session.selectLayer(try layer("A", in: session).id)
        session.locksTransformRatio = false
        let drag = try #require(session.beginTransformDrag(at: CGPoint(x: 150, y: 120), handle: .resize(4)))
        session.dragTransform(drag, to: CGPoint(x: 170, y: 130), control: true)
        session.commitTransform()
        let transform = try layer("A", in: session).transform
        #expect(transform.origin == CGPoint(x: 50, y: 40))
        #expect(transform.size == CGSize(width: 120, height: 90))
    }

    /// The rotation handle turns the layer about its center, to whole degrees, and with Shift in 15° steps.
    @Test func theRotationHandleTurnsTheLayer() throws {
        let session = try session()
        session.selectLayer(try layer("A", in: session).id)
        let center = CGPoint(x: 100, y: 80), up = CGPoint(x: 100, y: 10)
        let drag = try #require(session.beginTransformDrag(at: up, handle: .rotate))
        // 50° around from straight up.
        let radians = 50 * CGFloat.pi / 180
        let turned = CGPoint(x: center.x + sin(radians) * 70, y: center.y - cos(radians) * 70)
        session.dragTransform(drag, to: turned)
        #expect(abs(session.transformEdit?.draft.rotation ?? 0) == 50)
        session.dragTransform(drag, to: turned, shift: true)
        #expect(abs(session.transformEdit?.draft.rotation ?? 0) == 45)
    }

    /// Command on a handle distorts, moving that corner alone, as in Photoshop.
    @Test func commandOnAHandleDistorts() throws {
        let session = try session()
        session.selectLayer(try layer("A", in: session).id)
        let drag = try #require(session.beginTransformDrag(at: CGPoint(x: 150, y: 120), handle: .resize(4), command: true))
        let before = try #require(session.transformEdit?.corners)
        #expect(session.dragTransform(drag, to: CGPoint(x: 160, y: 135)))
        let after = try #require(session.transformEdit?.corners)
        #expect(after[2] == CGPoint(x: before[2].x + 10, y: before[2].y + 15))
        #expect(after[0] == before[0])
    }

    /// A move near the canvas's edge snaps to it, and shows the line it snapped to; Control drags freely.
    @Test func aMoveSnapsToTheCanvasEdgeUnlessControlIsHeld() throws {
        let session = try session()
        session.selectLayer(try layer("A", in: session).id)
        let drag = try #require(session.beginTransformDrag(at: CGPoint(x: 100, y: 80), handle: nil))
        session.dragTransform(drag, to: CGPoint(x: 53, y: 80))
        #expect(session.transformEdit?.draft.origin.x == 0)
        #expect(session.snapGuides.xs == [0])
        session.dragTransform(drag, to: CGPoint(x: 53, y: 80), control: true)
        #expect(session.transformEdit?.draft.origin.x == 3)
    }
}
