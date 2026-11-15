import AppKit
import Testing
@testable import Compositor

/// Option- and Command-scroll zoom in as the wheel turns away from you and out as it turns toward you, whichever way
/// natural scrolling is set (#336).
@MainActor struct ScrollZoomTests {
    @Test func theWheelTurnedAwayZoomsInWithNaturalScrollingOnOrOff() {
        // Natural scrolling off: turning the wheel away from you comes as a positive delta.
        #expect(CanvasView.wheelZoomFactor(deltaY: 10, inverted: false) > 1)
        #expect(CanvasView.wheelZoomFactor(deltaY: -10, inverted: false) < 1)
        // Natural scrolling on: the same turn comes flipped, and is flipped back.
        #expect(CanvasView.wheelZoomFactor(deltaY: -10, inverted: true) > 1)
        #expect(CanvasView.wheelZoomFactor(deltaY: 10, inverted: true) < 1)
        #expect(CanvasView.wheelZoomFactor(deltaY: 0, inverted: false) == 1)
    }
}
