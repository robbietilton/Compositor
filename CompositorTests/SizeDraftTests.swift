import Foundation
import Testing
@testable import Compositor

/// The Canvas Size and Image Size dialogs' arithmetic, which every platform's dialogs share.
struct SizeDraftTests {
    /// Locked, a new width takes the height with it; a percentage counts from the image's own size, and print units
    /// from its resolution.
    @Test func imageSizeConvertsUnitsAndKeepsTheRatio() {
        var draft = ImageSizeDraft(width: 1000, height: 500, resolution: 100)
        draft.set(2000, widthAxis: true)
        #expect(draft.width == 2000 && draft.height == 1000)
        draft.unit = .percent
        #expect(draft.displayed(widthAxis: false) == 200)
        draft.set(50, widthAxis: false)
        #expect(draft.width == 500 && draft.height == 250)
        draft.unit = .inches
        #expect(draft.displayed(widthAxis: true) == 5)
        draft.locked = false
        draft.set(4, widthAxis: false)
        #expect(draft.width == 500 && draft.height == 400)
        draft.unit = .centimeters
        #expect(abs(draft.displayed(widthAxis: true) - 12.7) < 0.0001)
        #expect(draft.options?.width == 500 && draft.options?.height == 400)
    }

    /// Without resampling a print size sets the resolution and leaves the pixels; resampling, a new resolution keeps a
    /// print size, so the pixels scale from the last usable resolution.
    @Test func withoutResamplingOnlyTheResolutionChanges() {
        var draft = ImageSizeDraft(width: 1000, height: 500, resolution: 100)
        draft.set(2000, widthAxis: true)
        draft.setResample(false)
        #expect(draft.width == 1000 && draft.height == 500)
        #expect(draft.locked && draft.unit == .inches)
        #expect(draft.units == [.inches, .centimeters])
        // 1000 pixels over 5 inches.
        draft.set(5, widthAxis: true)
        #expect(draft.resolution == 200 && draft.width == 1000)

        draft.setResample(true)
        draft.setResolution(300)
        #expect(draft.width == 1500 && draft.height == 750)
        draft.setResolution(0)
        #expect(!draft.valid && draft.options == nil)
        draft.setResolution(150)
        #expect(draft.width == 750 && draft.height == 375)
    }

    /// Scrubbing stays within a side's limit and, resampling, the surface's; relative sizes count from the current one.
    @Test func scrubbingStaysWithinTheLimits() {
        var image = ImageSizeDraft(width: 1000, height: 500, resolution: 100)
        #expect(image.scrubRange(widthAxis: true) == 2...sqrt(200_000_000))
        #expect(image.scrubSensitivity(widthAxis: true) == 1)
        image.locked = false
        #expect(image.scrubRange(widthAxis: false) == 1...30_000)
        image.unit = .percent
        #expect(image.scrubSensitivity(widthAxis: true) == 0.1)
        image.setResample(false)
        #expect(image.scrubRange(widthAxis: true) == 1000 / 9600...1000)
        #expect(image.scrubSensitivity(widthAxis: true) == 0.01)

        var canvas = CanvasSizeDraft(width: 1000, height: 500, resolution: 100)
        #expect(canvas.scrubRange(widthAxis: true) == 1...30_000)
        canvas.locked = true
        canvas.relative = true
        canvas.unit = .percent
        let range = canvas.scrubRange(widthAxis: true)
        #expect(abs(range.lowerBound + 99.8) < 0.0001 && abs(range.upperBound - 2900) < 0.0001)
        #expect(canvas.scrubSensitivity(widthAxis: true) == 0.1)
        canvas.unit = .inches
        #expect(canvas.scrubSensitivity(widthAxis: false) == 0.01)
    }
}
