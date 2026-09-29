import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct CameraRawPresetTests {
    /// Something moved in every group, so a field left out of the preset shows up as a difference.
    private func edited() -> CameraRawSettings {
        var settings = CameraRawSettings()
        settings.whiteBalance = .custom
        settings.temperature = 12; settings.tint = -8; settings.exposure = 0.7; settings.contrast = 15
        settings.highlights = -30; settings.shadows = 25; settings.whites = 5; settings.blacks = -5
        settings.vibrance = 20; settings.saturation = -10; settings.texture = 10; settings.clarity = 12; settings.dehaze = 4
        settings.glow = 30; settings.glowStyle = .bloom; settings.glowRange = 10; settings.glowSpread = -5; settings.glowWarmth = 7
        settings.vignetteAmount = -20; settings.vignetteStyle = .paintOverlay; settings.vignetteMidpoint = 40
        settings.vignetteRoundness = 10; settings.vignetteFeather = 60; settings.vignetteHighlights = 5
        settings.grainAmount = 15; settings.grainSize = 30; settings.grainRoughness = 40
        settings.curve.shadows = 10; settings.curve.rgb = CameraRawCurveSettings.mediumContrast; settings.curve.refineSaturation = 20
        settings.mixer.hue[2] = 15; settings.mixer.saturation[5] = -20; settings.mixer.luminance[0] = 10
        settings.mixer.points = [CameraRawPointColor(hue: 30, saturation: 0.5, luminance: 0.5, hueShift: 10)]
        settings.grading.shadows = CameraRawGradeWheel(hue: 200, saturation: 20, luminance: -5); settings.grading.balance = 10
        settings.detail.sharpenAmount = 40; settings.detail.noiseLuminance = 20
        settings.optics.enableLensProfile = true; settings.optics.distortion = 5; settings.optics.purpleAmount = 10
        settings.geometry.vertical = 10; settings.geometry.projection = .rectilinear; settings.geometry.constrainCrop = true
        settings.calibration.process = .version6; settings.calibration.redHue = 12
        return settings.normalized
    }

    @Test func presetsRoundTripWithoutGuides() throws {
        var settings = edited()
        settings.geometry.upright = .guided
        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.1, endX: 0.1, endY: 0.9)]
        // Showing which pixels a point color picks is a view of the panel, not part of the look.
        settings.mixer.points[0].visualize = true
        let data = try JSONSerialization.data(withJSONObject: settings.presetObject)
        let read = try #require(CameraRawSettings.preset(from: try JSONSerialization.jsonObject(with: data)))
        var expected = settings
        expected.geometry.guides = []
        expected.mixer.points[0].visualize = false
        #expect(read == expected)
    }

    @Test func missingFieldsTakeTheirDefaultsAndUnknownOnesAreIgnored() throws {
        var object = try #require(edited().presetObject as? [String: Any])
        object["exposure"] = nil
        object["grading"] = nil
        object["aSliderFromTheFuture"] = 42
        let read = try #require(CameraRawSettings.preset(from: object))
        #expect(read.exposure == 0)
        #expect(read.grading == CameraRawGradingSettings())
        #expect(read.contrast == 15, "the rest is kept")
    }

    /// A point color saved before one of its fields existed takes that field's default, like any other slider.
    @Test func pointColorsMissingAFieldKeepTheirDefaults() throws {
        var object = try #require(edited().presetObject as? [String: Any])
        var mixer = try #require(object["mixer"] as? [String: Any])
        var point = try #require((mixer["points"] as? [[String: Any]])?.first)
        point["hueRange"] = nil
        mixer["points"] = [point]
        object["mixer"] = mixer
        let read = try #require(CameraRawSettings.preset(from: object))
        #expect(read.mixer.points.first?.hueShift == 10)
        #expect(read.mixer.points.first?.hueRange == CameraRawPointColor().hueRange)
    }

    @Test func readingRepairsWhatWouldBreakTheFilter() throws {
        var object = try #require(CameraRawSettings().presetObject as? [String: Any])
        object["exposure"] = 99
        var mixer = try #require(object["mixer"] as? [String: Any])
        mixer["hue"] = [10, 20, 30]
        object["mixer"] = mixer
        let read = try #require(CameraRawSettings.preset(from: object))
        #expect(read.exposure == 5)
        #expect(read.mixer.hue == [10, 20, 30, 0, 0, 0, 0, 0] && read.mixer.saturation.count == 8 && read.mixer.luminance.count == 8)
        #expect(CameraRawSettings.preset(from: [1, 2, 3]) == nil)
        object["glowStyle"] = "Sparkle"
        #expect(CameraRawSettings.preset(from: object) == nil, "an unknown choice can't be read")
    }

    private func storeURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraRawPresetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("CameraRawPresets.json")
    }

    @Test func savedPresetsComeBackSortedByName() throws {
        let url = try storeURL()
        let store = CameraRawPresetStore(url: url)
        #expect(store.presets.isEmpty, "no file yet")
        try store.save(edited(), as: "  warm portrait ")
        try store.save(CameraRawSettings(), as: "Base")
        let reopened = CameraRawPresetStore(url: url)
        #expect(reopened.presets.map(\.name) == ["Base", "warm portrait"], "trimmed, sorted ignoring case")
        #expect(reopened.preset(named: "WARM PORTRAIT")?.settings == edited())
    }

    @Test func aNameDifferingOnlyInCaseReplaces() throws {
        let store = CameraRawPresetStore(url: try storeURL())
        try store.save(CameraRawSettings(), as: "Portrait")
        try store.save(edited(), as: "portrait")
        #expect(store.presets.map(\.name) == ["portrait"])
        #expect(store.presets.first?.settings == edited())
    }

    @Test func renameAndDelete() throws {
        let store = CameraRawPresetStore(url: try storeURL())
        try store.save(CameraRawSettings(), as: "One")
        try store.save(edited(), as: "Two")
        #expect(throws: CameraRawPresetError.self) { try store.rename("One", to: "two") }
        try store.rename("One", to: "one again")
        try store.rename("Two", to: "TWO")
        #expect(store.presets.map(\.name) == ["one again", "TWO"], "renaming to the same name in other case is allowed")
        try store.delete("one again")
        #expect(store.presets.map(\.name) == ["TWO"])
        #expect(CameraRawPresetStore.validName("   ") == nil)
        #expect(CameraRawPresetStore.validName(String(repeating: "a", count: 65)) == nil)
        #expect(CameraRawPresetStore.validName(" Film ") == "Film")
        #expect(throws: CameraRawPresetError.self) { try store.save(CameraRawSettings(), as: "") }
    }

    @Test func unreadablePresetsAreKeptInTheFile() throws {
        let url = try storeURL()
        let file: [String: Any] = ["version": 1, "presets": [
            ["name": "From the future", "settings": ["glowStyle": "Sparkle"]],
            ["name": "Old", "settings": ["exposure": 1]],
        ]]
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let store = CameraRawPresetStore(url: url)
        #expect(store.presets.map(\.name) == ["Old"])
        #expect(store.presets.first?.settings.exposure == 1)
        try store.save(CameraRawSettings(), as: "New")
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let names = (saved["presets"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names?.contains("From the future") == true, "a preset this build can't read survives")
    }

    @Test func aCorruptFileIsSetAsideNotOverwritten() throws {
        let url = try storeURL()
        try Data("not json".utf8).write(to: url)
        let store = CameraRawPresetStore(url: url)
        #expect(store.presets.isEmpty)
        try store.save(CameraRawSettings(), as: "Fresh")
        let backup = url.appendingPathExtension("bak")
        #expect(try Data(contentsOf: backup) == Data("not json".utf8))
        #expect(CameraRawPresetStore(url: url).presets.map(\.name) == ["Fresh"])
    }

    private func session(red: CGFloat = 160 / 255, green: CGFloat = 140 / 255, blue: CGFloat = 120 / 255) throws -> EditorSession {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Warm"))
        return session
    }

    @Test func applyingAPresetSetsTheSlidersAndKeepsThePanelOpen() async throws {
        let session = try session()
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        var drawn = edit.settings
        drawn.cameraRaw.geometry.upright = .guided
        drawn.cameraRaw.geometry.guides = [CameraRawGeometryGuide(startX: 0.2, startY: 0.1, endX: 0.2, endY: 0.9)]
        session.updateFilter(drawn, preview: true)
        #expect(session.cameraRawPresetSettings?.geometry.guides.isEmpty == true, "what Save would keep leaves the lines out")
        await session.applyCameraRawPreset(CameraRawPreset(name: "Look", settings: edited()))
        #expect(session.filterEdit === edit)
        #expect(edit.settings.cameraRaw == edited(), "every slider, and the drawn lines go with the old look")
        edit.committing = true
        await session.applyCameraRawPreset(CameraRawPreset(name: "Plain", settings: CameraRawSettings()))
        #expect(edit.settings.cameraRaw == edited(), "ignored once OK is pressed")
    }

    @Test func presetsApplyOnlyToCameraRaw() async throws {
        let session = try session()
        session.beginFilter(.gaussianBlur)
        let before = try #require(session.filterEdit).settings
        #expect(session.cameraRawPresetSettings == nil)
        await session.applyCameraRawPreset(CameraRawPreset(name: "Look", settings: edited()))
        #expect(session.filterEdit?.settings == before)
    }

    /// A preset saved with White Balance > Auto balances the image it's applied to, not the one it was saved on.
    @Test func anAutoWhiteBalancePresetRunsAutoAgain() async throws {
        let session = try session()
        session.beginFilter(.cameraRaw)
        var look = CameraRawSettings()
        look.whiteBalance = .auto
        look.temperature = 50 // warmer still: the opposite of what this image needs
        look.contrast = 20
        await session.applyCameraRawPreset(CameraRawPreset(name: "Auto", settings: look))
        let applied = try #require(session.filterEdit).settings.cameraRaw
        #expect(applied.whiteBalance == .auto && applied.contrast == 20)
        #expect(applied.temperature < 0, "this warm image's own balance, not the saved one: \(applied.temperature)")
    }

    @Test func savingAsksBeforeReplacing() throws {
        let store = CameraRawPresetStore(url: try storeURL())
        try store.save(CameraRawSettings(), as: "Film")
        #expect(CameraRawPresetMenu.saveStep(for: "  ", in: store) == .invalidName)
        #expect(CameraRawPresetMenu.saveStep(for: " Matte ", in: store) == .save("Matte"))
        #expect(CameraRawPresetMenu.saveStep(for: "FILM", in: store) == .confirmReplace(existing: "Film", name: "FILM"))
    }

    @Test func menuFitsThePanel() throws {
        let session = try session()
        session.beginFilter(.cameraRaw)
        let store = CameraRawPresetStore(url: try storeURL())
        let empty = NSHostingView(rootView: CameraRawPresetMenu(session: session, store: store))
        #expect(empty.fittingSize.width > 0 && empty.fittingSize.width < FloatingPanelController.dockedWidth)
        try store.save(CameraRawSettings(), as: String(repeating: "Long name ", count: 6))
        let full = NSHostingView(rootView: CameraRawPresetMenu(session: session, store: store))
        #expect(full.fittingSize.width < FloatingPanelController.dockedWidth, "a long name stays in the menu, not the button")
    }
}
