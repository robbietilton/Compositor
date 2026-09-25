import AppKit
import Testing
@testable import Compositor

/// The snap hook runs in AppKit before a native slider cell starts tracking a track press.
@MainActor
@Suite(.serialized)
struct SliderSnapTests {
    @Test func clickingTheTrackSnapsBeforeNativeTrackingBegins() throws {
        SliderSnap.install()
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 260, height: 50), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let slider = NSSlider(value: 0.1, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = CGRect(x: 20, y: 10, width: 220, height: 30)
        window.contentView?.addSubview(slider)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        let cell = try #require(slider.cell as? NSSliderCell)
        let press = NSPoint(x: slider.bounds.width * 0.9, y: slider.bounds.midY)
        _ = cell.startTracking(at: press, in: slider)
        #expect(abs(slider.doubleValue - 0.94) < 0.02, "value should snap under the click before tracking: \(slider.doubleValue)")
    }
}
