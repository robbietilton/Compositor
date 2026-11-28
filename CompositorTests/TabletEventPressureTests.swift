import AppKit
import Testing
@testable import Compositor

/// The Mac's canvas telling a tablet's events from a mouse's. What the pressure then does to a stroke is in
/// PenPressureTests, which needs no AppKit.
@MainActor
struct TabletEventPressureTests {
    /// Only a tablet's events carry a pressure to follow; a mouse's, even pressed hard on a Force Touch trackpad, don't.
    @Test func theCanvasReadsPressureFromATabletOnly() throws {
        func event(tablet: Bool, pressure: Double) throws -> NSEvent {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                              mouseCursorPosition: .zero, mouseButton: .left))
            event.setDoubleValueField(.mouseEventPressure, value: pressure)
            if tablet { event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue)) }
            return try #require(NSEvent(cgEvent: event))
        }
        #expect(abs(try #require(CanvasView.penPressure(try event(tablet: true, pressure: 0.3))) - 0.3) < 0.01)
        #expect(CanvasView.penPressure(try event(tablet: false, pressure: 0.3)) == nil)
    }
}
