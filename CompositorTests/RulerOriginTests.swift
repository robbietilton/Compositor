import AppKit
import Testing
@testable import Compositor

@MainActor
struct RulerOriginTests {
    /// A session with View › Snap To on or off for the test, put back as it was afterward: the setting is saved.
    private func withSnapping(_ enabled: Bool, _ body: (EditorSession) async throws -> Void) async rethrows {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        let saved = (session.snapEnabled, session.snapToDocumentBounds)
        session.snapEnabled = enabled
        session.snapToDocumentBounds = true
        defer { session.snapEnabled = saved.0; session.snapToDocumentBounds = saved.1 }
        try await body(session)
    }

    @Test func draggingOutOfTheCornerMovesTheZeroPointOnRelease() async {
        await withSnapping(false) { session in
            #expect(session.rulerZero == .zero)
            session.beginRulerOriginDrag(at: CGPoint(x: 10.4, y: 20.6))
            session.moveRulerOriginDrag(to: CGPoint(x: 120.3, y: 80.7))
            #expect(session.rulerOriginDrag == CGPoint(x: 120, y: 81), "the crosshair sits on whole pixels")
            #expect(session.rulerZero == .zero, "the rulers keep counting from the old zero until release")
            session.finishRulerOriginDrag(cancel: false)
            #expect(session.rulerZero == CGPoint(x: 120, y: 81))
            #expect(session.rulerOriginDrag == nil)
        }
    }

    /// A plain click in the corner, a drag let go back over the rulers, or Escape leaves the zero point alone.
    @Test func aCancelledDragLeavesTheZeroPointWhereItWas() async {
        await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 50, y: 40))
            session.beginRulerOriginDrag(at: CGPoint(x: 200, y: 200))
            session.moveRulerOriginDrag(to: CGPoint(x: 220, y: 210))
            session.finishRulerOriginDrag(cancel: true)
            #expect(session.rulerZero == CGPoint(x: 50, y: 40) && session.rulerOriginDrag == nil)
        }
    }

    @Test func theZeroPointSnapsLikeAGuide() async {
        await withSnapping(true) { session in
            let tolerance = TransformSnap.distance / max(session.viewport.pointsPerPixel, 0.0001)
            // Just off the canvas's middle and its top edge, well inside the snap distance.
            session.beginRulerOriginDrag(at: CGPoint(x: 200 + tolerance / 2, y: tolerance / 2))
            #expect(session.rulerOriginDrag == CGPoint(x: 200, y: 0))
            session.finishRulerOriginDrag(cancel: false)
            #expect(session.rulerZero == CGPoint(x: 200, y: 0))
        }
    }

    @Test func doubleClickingTheCornerPutsZeroBackOnTheTopLeft() async {
        await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 75, y: 25))
            session.resetRulerOrigin()
            #expect(session.rulerZero == .zero && session.rulerOrigin == nil)
        }
    }

    /// The zero point belongs to the canvas it was set on: a new size or a new document counts from the corner
    /// again, and undoing the size change brings it back.
    @Test func aNewCanvasCountsFromItsCornerAgain() async throws {
        try await withSnapping(false) { session in
            session.setRulerZero(CGPoint(x: 100, y: 60))
            let resized = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()),
                                                                 to: CanvasSizeOptions(width: 500, height: 300))
            session.applyDocumentSize(resized, actionName: "Canvas Size")
            #expect(session.document?.size == CGSize(width: 500, height: 300))
            #expect(session.rulerZero == .zero)
            session.undo()
            #expect(session.rulerZero == CGPoint(x: 100, y: 60))

            session.createDocument(width: 400, height: 300)
            #expect(session.rulerZero == .zero, "a new document, even at the same size")
        }
    }

    /// The numbers before the zero point count backwards from it.
    @Test func rulerTicksCountBackwardsBeforeTheZeroPoint() {
        #expect(CanvasRulerNSView.ticks(from: 0, to: 300, zero: 0, minor: 100) == [0, 100, 200, 300])
        #expect(CanvasRulerNSView.ticks(from: 0, to: 300, zero: 120, minor: 40) == [-120, -80, -40, 0, 40, 80, 120, 160, 200])
        #expect(CanvasRulerNSView.label(-120) == "-120" && CanvasRulerNSView.label(-0.2) == "0")
    }
}
