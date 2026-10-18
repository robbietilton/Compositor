import Testing
@testable import Compositor

/// The colored slider tracks, Camera Raw's, Hue/Saturation's and Color Balance's: their colors, left to right, in sRGB,
/// as the Mac has always drawn them.
@MainActor struct SliderTrackTests {
    /// The track's colors as sRGB components.
    private func srgb(_ track: CameraRawSliderTrack) -> [[Double]]? {
        track.colors?.map { [$0.red, $0.green, $0.blue].map(Double.init) }
    }

    private func matches(_ track: CameraRawSliderTrack, _ expected: [[Double]]) -> Bool {
        guard let colors = srgb(track), colors.count == expected.count else { return false }
        return zip(colors, expected).allSatisfy { pair in zip(pair.0, pair.1).allSatisfy { abs($0 - $1) <= 1.0 / 255 } }
    }

    @Test func aPlainTrackIsTheSystems() {
        #expect(srgb(.plain) == nil)
    }

    @Test func cameraRawsTracks() {
        #expect(matches(.temperature, [[0.22, 0.46, 0.95], [0.98, 0.82, 0.18]]))
        #expect(matches(.tint, [[0.28, 0.70, 0.34], [0.70, 0.40, 0.64]]))
        #expect(matches(.chroma, [[0.62, 0.62, 0.64], [0.86, 0.18, 0.20]]))
        #expect(matches(.hue(0), [[0.9, 0.135, 0.7725], [0.9, 0.7725, 0.135]]))
        #expect(matches(.hue(350), [[0.9, 0.135, 0.9], [0.9, 0.645, 0.135]]))
        #expect(matches(.saturation(120), [[0.55, 0.55, 0.56], [0.09, 0.9, 0.09]]))
        #expect(matches(.luminance(240), [[0.081, 0.081, 0.18], [0.6175, 0.6175, 0.95]]))
    }

    @Test func theSpectrumGoesRoundTheHueCircle() {
        #expect(matches(.spectrum(0), [[0.135, 0.9, 0.9], [0.135, 0.5175, 0.9], [0.135, 0.135, 0.9], [0.5175, 0.135, 0.9],
                                       [0.9, 0.135, 0.9], [0.9, 0.135, 0.5175], [0.9, 0.135, 0.135], [0.9, 0.5175, 0.135],
                                       [0.9, 0.9, 0.135], [0.5175, 0.9, 0.135], [0.135, 0.9, 0.135], [0.135, 0.9, 0.5175],
                                       [0.135, 0.9, 0.9]]))
        #expect(matches(.spectrum(180), [[0.9, 0.135, 0.135], [0.9, 0.5175, 0.135], [0.9, 0.9, 0.135], [0.5175, 0.9, 0.135],
                                         [0.135, 0.9, 0.135], [0.135, 0.9, 0.5175], [0.135, 0.9, 0.9], [0.135, 0.5175, 0.9],
                                         [0.135, 0.135, 0.9], [0.5175, 0.135, 0.9], [0.9, 0.135, 0.9], [0.9, 0.135, 0.5175],
                                         [0.9, 0.135, 0.135]]))
    }

    /// Hue/Saturation's Lightness, black to white, and Color Balance's three, each color to its opposite.
    @Test func opposingTracks() {
        #expect(matches(HueSaturationSettings.lightnessTrack, [[0, 0, 0], [1, 1, 1]]))
        #expect(matches(.cyanRed, [[0.10, 0.72, 0.80], [0.86, 0.18, 0.20]]))
        #expect(matches(.magentaGreen, [[0.80, 0.22, 0.70], [0.24, 0.70, 0.30]]))
        #expect(matches(.yellowBlue, [[0.95, 0.82, 0.18], [0.22, 0.40, 0.92]]))
    }

    /// Hue/Saturation's Hue track centers on the range's color, red for Master, and runs red to red while colorizing;
    /// its Saturation track runs gray to the range's color, Master's to a red, and to the hue being set while
    /// colorizing. A double-click puts a slider back to no change, or to Photoshop's colorize start.
    @Test func hueSaturationsTracksFollowItsRange() {
        var settings = HueSaturationSettings()
        #expect(settings.hueTrack == .spectrum(0) && settings.saturationTrack == .chroma)
        settings.range = .reds
        #expect(settings.hueTrack == .spectrum(0) && settings.saturationTrack == .saturation(0))
        settings.range = .greens
        #expect(settings.hueTrack == .spectrum(120) && settings.saturationTrack == .saturation(120))
        #expect(settings.resetValues == HueSaturationSettings())
        settings = .colorizeStart
        settings.hue = 200
        #expect(settings.hueTrack == .spectrum(180) && settings.saturationTrack == .saturation(200))
        #expect(settings.resetValues == .colorizeStart)
    }
}
