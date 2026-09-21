import AppKit
import Combine
import SwiftUI
import Testing
@testable import Compositor

/// Clicking a slider's track must snap the knob to the click, not glide it there.
@MainActor
@Suite(.serialized)
struct SliderSnapTests {
    private final class Model: ObservableObject {
        @Published var value = 0.1
        var log: [String] = []
    }
    private struct Probe: View {
        @ObservedObject var model: Model
        var body: some View {
            Slider(value: Binding(get: { model.value }, set: { model.value = $0; model.log.append("set") }), in: 0...1,
                   onEditingChanged: { model.log.append($0 ? "began" : "ended") })
                .frame(width: 200)
        }
    }

    /// Left edge of the knob as drawn, in slider coordinates. The drawn knob is the slider's only
    /// small subview; `knobRect` can't be used, since it follows the value, not the animation.
    private func drawnKnobX(in slider: NSSlider) -> CGFloat? {
        func find(_ view: NSView) -> NSView? {
            for sub in view.subviews {
                if sub.frame.width < 60 { return sub }
                if let found = find(sub) { return found }
            }
            return nil
        }
        return find(slider).map { $0.convert($0.bounds, to: slider).minX }
    }

    @Test func clickingTheTrackSnapsTheKnobAndStillEditsTheValue() async throws {
        SliderSnap.install()
        let model = Model()
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 260, height: 50), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: Probe(model: model))
        hosting.frame = CGRect(x: 0, y: 0, width: 260, height: 50)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: LegacyDelay.milliseconds(300))
        func sliders(_ view: NSView) -> [NSSlider] { (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap(sliders) }
        let slider = try #require(sliders(hosting).first)
        let start = try #require(drawnKnobX(in: slider))
        let point = slider.convert(NSPoint(x: slider.bounds.width * 0.9, y: slider.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(down) // tracks the whole click, since the real mouse button is up
        #expect(abs(model.value - 0.94) < 0.02, "value \(model.value)")
        #expect(model.log.first == "began" && model.log.last == "ended" && model.log.contains("set"), "\(model.log)")

        try await Task.sleep(nanoseconds: LegacyDelay.milliseconds(50))
        let early = try #require(drawnKnobX(in: slider))
        try await Task.sleep(nanoseconds: LegacyDelay.milliseconds(400))
        let settled = try #require(drawnKnobX(in: slider))
        #expect(settled - start > 100, "the knob never moved: \(start) → \(settled)")
        #expect(abs(early - settled) <= 2, "the knob glided: \(early) after 50 ms, \(settled) once settled")
    }
}
