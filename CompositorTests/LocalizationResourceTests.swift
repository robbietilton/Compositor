import AppKit
import CameraRawHostContract
import Testing
@testable import Compositor

@MainActor
struct LocalizationResourceTests {
    private func languageBundle(_ language: String, in bundle: Bundle) throws -> Bundle {
        let path = try #require(bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func strings(_ language: String, in bundle: Bundle) throws -> [String: String] {
        let localized = try languageBundle(language, in: bundle)
        let url = try #require(localized.url(forResource: "Localizable", withExtension: "strings"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    private func pluginBundle() throws -> Bundle {
        let root = try #require(Bundle.main.privateFrameworksURL)
        return try #require(Bundle(url: root.appendingPathComponent("CameraRawPlugin.framework")))
    }

    private func placeholders(_ string: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:([0-9]+)\$)?[-+#0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?((?:ll|l|hh|h|z|t|j)?[diuoxXfFeEgGaAcCsSp@])"#)
        let text = string as NSString
        return expression.matches(in: string, range: NSRange(location: 0, length: text.length))
            .enumerated().map { index, match in
                let position = match.range(at: 1).location == NSNotFound ? String(index + 1) : text.substring(with: match.range(at: 1))
                return position + ":" + text.substring(with: match.range(at: 2))
            }.sorted()
    }

    @Test func appAndIndependentPluginShipCompleteCatalogs() throws {
        for bundle in [Bundle.main, try pluginBundle()] {
            let english = try strings("en", in: bundle)
            let chinese = try strings("zh-Hans", in: bundle)
            #expect(!english.isEmpty)
            #expect(Set(english.keys) == Set(chinese.keys))
            for (key, value) in english {
                let translated = try #require(chinese[key])
                #expect(!translated.isEmpty || value.isEmpty)
                #expect(try placeholders(value) == placeholders(translated), "Format arguments changed for \(key)")
            }
        }
    }

    @Test func appAndPluginUseTheSameLaunchLanguage() throws {
        let language = try #require(Bundle.main.preferredLocalizations.first)
        #expect(["en", "zh-Hans"].contains(language))
        print("Localization launch language: \(language); preferred: \(Locale.preferredLanguages)")
        let plugin = try pluginBundle()
        #expect(plugin.preferredLocalizations.first == language)
        #expect(AppLocalization.string("Language") == (language == "zh-Hans" ? "语言" : "Language"))
        #expect(plugin.localizedString(forKey: "Apply", value: nil, table: nil) == (language == "zh-Hans" ? "应用" : "Apply"))
    }

    @Test func explicitLanguageLookupAndUnknownKeyFallback() throws {
        let chinese = try languageBundle("zh-Hans", in: .main)
        #expect(AppLocalization.string("Follow System", bundle: chinese) == "跟随系统")
        #expect(AppLocalization.string("Camera Raw Plugin…", bundle: chinese) == "Camera Raw 插件…")
        #expect(AppLocalization.string("Language", bundle: chinese) == "语言")
        #expect(AppLocalization.string("unknown.100%.key", bundle: chinese) == "unknown.100%.key")
        let english = try languageBundle("en", in: .main)
        #expect(AppLocalization.string("Language", bundle: english) == "Language")
        let plugin = try languageBundle("zh-Hans", in: pluginBundle())
        #expect(plugin.localizedString(forKey: "Apply", value: nil, table: nil) == "应用")
        #expect(plugin.localizedString(forKey: "Compare with Original", value: nil, table: nil) == "与原图对比")
    }

    @Test func formattedUserTextIsNotTranslatedOrInterpretedAsAFormat() throws {
        let chinese = try languageBundle("zh-Hans", in: .main)
        let template = AppLocalization.string("The saved settings on “%1$@” will be removed. Source pixels are kept. You can undo this change.", bundle: chinese)
        let name = "My %1$@ layer 100% 测试"
        let message = String(format: template, name)
        #expect(message.contains(name))
        #expect(message.contains("源像素"))
    }

    @Test func pluginMetadataIDsAndDefaultsStayMachineReadable() throws {
        let session = EditorSession()
        let context = try BrushRaster.context(width: 2, height: 2, mask: false)
        let image = try #require(context.makeImage())
        session.createDocument(width: 2, height: 2)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Source 100%"))
        let layer = try #require(session.activeLayer)
        let edit = try CameraRawPluginEdit(session: session, layer: layer, documentID: #require(session.document?.id))
        let controls = edit.controls
        let expectedIDs = """
        temperature tint exposure contrast highlights shadows whites blacks vibrance saturation
        curve.shadows curve.darks curve.lights curve.highlights curve.refineSaturation
        grading.shadows.hue grading.shadows.saturation grading.shadows.luminance
        grading.midtones.hue grading.midtones.saturation grading.midtones.luminance
        grading.highlights.hue grading.highlights.saturation grading.highlights.luminance
        grading.global.hue grading.global.saturation grading.global.luminance grading.blending grading.balance
        texture clarity dehaze glow glowRange glowSpread glowWarmth
        vignetteAmount vignetteMidpoint vignetteRoundness vignetteFeather vignetteHighlights
        grainAmount grainSize grainRoughness detail.sharpenAmount detail.sharpenRadius detail.sharpenDetail
        detail.sharpenMasking detail.noiseLuminance detail.noiseColor optics.distortion optics.vignetteAmount
        geometry.vertical geometry.horizontal geometry.aspect geometry.scale geometry.offsetX geometry.offsetY geometry.rotate
        calibration.shadowTint calibration.redHue calibration.redSaturation calibration.greenHue calibration.greenSaturation
        calibration.blueHue calibration.blueSaturation
        """.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(controls.map(\.id) == expectedIDs)
        #expect(controls.count == 66)
        #expect(Set(controls.map(\.group)).count == 11)
        let payload = try #require(JSONSerialization.jsonObject(with: edit.initialPayload) as? [String: Any])
        for control in controls {
            var value: Any = payload
            for key in control.id.split(separator: ".") { value = try #require((value as? [String: Any])?[String(key)]) }
            #expect((value as? NSNumber)?.doubleValue == control.defaultValue)
            #expect(control.lowerBound < control.upperBound)
        }
        #expect(controls.first { $0.id == "exposure" }?.lowerBound == -5)
        #expect(controls.first { $0.id == "detail.sharpenAmount" }?.upperBound == 150)
        #expect(LayerBlendMode.normal.rawValue == "Normal")
        #expect(BrushToolMode.paint.rawValue == "Paint")
        #expect(CameraRawSettings().whiteBalance.rawValue == "Custom")
    }
}
