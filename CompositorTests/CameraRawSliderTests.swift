import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawSliderTests {
    @Test func colorTracksRunFromTheCoolOrMutedEndToTheWarmOrStrongEnd() throws {
        let temperature = try #require(CameraRawSliderTrack.temperature.colors)
        let cool = try #require(temperature.first)
        let warm = try #require(temperature.last)
        #expect(cool.blueComponent > warm.blueComponent)
        let tint = try #require(CameraRawSliderTrack.tint.colors)
        let green = try #require(tint.first)
        let mauve = try #require(tint.last)
        #expect(green.greenComponent > mauve.greenComponent)
        let chroma = try #require(CameraRawSliderTrack.chroma.colors)
        let gray = try #require(chroma.first)
        let red = try #require(chroma.last)
        #expect(abs(gray.redComponent - gray.greenComponent) < 0.05)
        #expect(red.redComponent > red.greenComponent + 0.4)
        #expect(CameraRawSliderTrack.plain.colors == nil)
    }

    @Test func temperatureBarIsBlueOnTheLeftAndADoubleClickHitsOnlyTheKnob() throws {
        let cell = GradientSliderCell()
        cell.minValue = -100
        cell.maxValue = 100
        cell.doubleValue = 0
        cell.gradientColors = CameraRawSliderTrack.temperature.colors
        let width = 200
        let height = 16
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let bitmap = try #require(rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        cell.drawBar(inside: NSRect(x: 0, y: 0, width: width, height: height), flipped: false)
        NSGraphicsContext.restoreGraphicsState()
        let left = try #require(bitmap.colorAt(x: 4, y: height / 2)?.usingColorSpace(.sRGB))
        let right = try #require(bitmap.colorAt(x: width - 4, y: height / 2)?.usingColorSpace(.sRGB))
        #expect(left.blueComponent > left.redComponent, "left is blue: \(left)")
        #expect(right.redComponent + right.greenComponent > right.blueComponent + 0.4, "right is yellow: \(right)")

        let slider = CameraRawSliderView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        slider.minValue = -100
        slider.maxValue = 100
        slider.doubleValue = 40
        let knob = (slider.cell as? NSSliderCell)?.knobRect(flipped: false) ?? .zero
        #expect(slider.isOnKnob(NSPoint(x: knob.midX, y: knob.midY)))
        #expect(!slider.isOnKnob(NSPoint(x: 2, y: knob.midY)))
    }

    @Test func trackClickValueMatchesTheClickedPosition() {
        let slider = CameraRawSliderView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        slider.minValue = -100
        slider.maxValue = 100
        let left = slider.value(at: NSPoint(x: 0, y: slider.bounds.midY))
        let center = slider.value(at: NSPoint(x: slider.bounds.midX, y: slider.bounds.midY))
        let right = slider.value(at: NSPoint(x: slider.bounds.maxX, y: slider.bounds.midY))
        #expect(left == -100)
        #expect(abs(center) < 1)
        #expect(right == 100)
    }
}
