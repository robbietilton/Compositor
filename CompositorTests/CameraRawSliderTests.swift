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

    @Test func colorBalanceTracksRunFromEachColorToItsOpposite() throws {
        let cyanRed = try #require(FilterSheet.cyanRedTrack.colors)
        #expect(cyanRed[0].blueComponent > cyanRed[0].redComponent && cyanRed[1].redComponent > cyanRed[1].blueComponent)
        let magentaGreen = try #require(FilterSheet.magentaGreenTrack.colors)
        #expect(magentaGreen[0].redComponent > magentaGreen[0].greenComponent && magentaGreen[1].greenComponent > magentaGreen[1].redComponent)
        let yellowBlue = try #require(FilterSheet.yellowBlueTrack.colors)
        #expect(yellowBlue[0].greenComponent > yellowBlue[0].blueComponent && yellowBlue[1].blueComponent > yellowBlue[1].greenComponent)
        let greens = try #require(CameraRawSliderTrack.luminance(120).colors?.last?.usingColorSpace(.sRGB))
        #expect(greens.greenComponent > greens.redComponent && greens.greenComponent > greens.blueComponent)
    }

    /// A press puts the knob's center under the pointer: the ends of the track are the ends of the range, and the
    /// middle is the middle.
    @Test func aPointOnTheTrackStandsForTheValueUnderIt() {
        #expect(SliderGeometry.fraction(atX: 0, width: 200) == 0)
        #expect(abs(SliderGeometry.fraction(atX: 100, width: 200) - 0.5) < 0.001)
        #expect(SliderGeometry.fraction(atX: 200, width: 200) == 1)
        for fraction in [0.0, 0.3, 1.0] {
            let x = SliderGeometry.knobCenter(fraction: fraction, width: 200)
            #expect(abs(SliderGeometry.fraction(atX: x, width: 200) - fraction) < 0.001)
        }
        #expect(SliderGeometry.fraction(of: 0, in: -100...100) == 0.5)
    }

    /// The fill ends at the knob's center, but is empty at the minimum and full at the maximum.
    @Test func theFillFollowsTheKnobAndReachesBothEnds() {
        #expect(SliderGeometry.fillWidth(fraction: 0, width: 200) == 0)
        #expect(SliderGeometry.fillWidth(fraction: 1, width: 200) == 200)
        #expect(abs(SliderGeometry.fillWidth(fraction: 0.5, width: 200) - SliderGeometry.knobCenter(fraction: 0.5, width: 200)) < 0.001)
        // Rising throughout, with no jump where the ramps meet the knob.
        let widths = stride(from: 0.0, through: 1.0, by: 0.001).map { SliderGeometry.fillWidth(fraction: $0, width: 200) }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 < 1 })
    }
}
