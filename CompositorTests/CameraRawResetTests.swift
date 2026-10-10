import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawResetTests {
    /// Every section moved away from its defaults, including choices and midpoints that no amount slider covers.
    private func edited() -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.exposure = 0.7; settings.contrast = 15; settings.highlights = -30; settings.shadows = 25
        settings.whites = 5; settings.blacks = -5
        settings.whiteBalance = .auto; settings.temperature = 12; settings.tint = -8; settings.vibrance = 20; settings.saturation = -10
        settings.texture = 10; settings.clarity = 12; settings.dehaze = 4
        settings.glow = 30; settings.glowStyle = .bloom; settings.glowRange = 10; settings.glowSpread = -5; settings.glowWarmth = 7
        settings.vignetteAmount = -20; settings.vignetteStyle = .paintOverlay; settings.vignetteMidpoint = 40
        settings.vignetteRoundness = 10; settings.vignetteFeather = 60; settings.vignetteHighlights = 5
        settings.grainAmount = 15; settings.grainSize = 30; settings.grainRoughness = 40
        settings.curve.shadows = 10; settings.curve.shadowSplit = 30; settings.curve.rgb = CameraRawCurveSettings.mediumContrast
        settings.mixer.hue[2] = 15; settings.mixer.points = [CameraRawPointColor(hue: 30, saturation: 0.5, luminance: 0.5, hueShift: 10)]
        settings.grading.shadows = CameraRawGradeWheel(hue: 200, saturation: 20, luminance: -5); settings.grading.blending = 70
        settings.detail.sharpenAmount = 40; settings.detail.sharpenRadius = 20
        settings.optics.enableLensProfile = true; settings.optics.purpleHueLow = 280
        settings.geometry.vertical = 10; settings.geometry.projection = .rectilinear
        settings.calibration.process = .version5; settings.calibration.redHue = 12
        return settings
    }

    @Test func resettingEverySectionGivesNewSettings() {
        var settings = edited()
        for group in CameraRawGroup.allCases {
            #expect(!settings.isDefault(group), "\(group) starts edited")
            settings = settings.resetting(group)
        }
        #expect(settings == CameraRawSettings(), "every setting belongs to a section")
    }

    @Test(arguments: CameraRawGroup.allCases)
    func resettingASectionLeavesTheOthers(_ group: CameraRawGroup) {
        let settings = edited()
        let reset = settings.resetting(group)
        #expect(reset.isDefault(group))
        for other in CameraRawGroup.allCases where other != group {
            #expect(reset.keeping(other) == settings.keeping(other), "resetting \(group) changed \(other)")
        }
    }

    @Test func effectsResetIncludesTheirChoicesAndMidpoints() {
        let reset = edited().resetting(.effects)
        #expect(reset.glowStyle == .diffusion && reset.vignetteStyle == .highlightPriority)
        #expect(reset.vignetteMidpoint == 50 && reset.vignetteFeather == 50 && reset.grainSize == 25 && reset.grainRoughness == 50)
        #expect(edited().resetting(.color).whiteBalance == .custom)
    }

    private func session() throws -> EditorSession {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        return session
    }

    /// The panel stays open, the section's sliders go back, and a section that was hidden shows again, so the next
    /// change to it isn't made unseen.
    @Test func resetInThePanelShowsTheSectionAgain() throws {
        let session = try session()
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        var settings = edit.settings
        settings.cameraRaw = edited()
        session.updateFilter(settings, preview: true)
        edit.showsCameraRawEffects = false
        session.resetCameraRaw(.effects)
        #expect(session.filterEdit === edit)
        #expect(edit.settings.cameraRaw == edited().resetting(.effects))
        #expect(edit.showsCameraRawEffects)
        edit.committing = true
        session.resetCameraRaw(.light)
        #expect(edit.settings.cameraRaw.exposure == 0.7, "ignored once OK is pressed")
    }
}
