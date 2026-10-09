import Foundation
import Testing
@testable import Compositor

struct AppLanguageTests {
    /// The languages this catalog ships. A test can add another id without a new Swift case.
    private let installed = ["en", "zh-Hans", "zh-Hant", "ja"]

    @Test func followsStoredChoiceAndOtherwiseTheSystem() {
        #expect(resolved(stored: "zh-Hans", system: ["en"]) == "zh-Hans")
        #expect(resolved(stored: "en", system: ["zh-CN"]) == "en")
        #expect(resolved(stored: nil, system: ["zh-Hans-CN", "en"]) == "zh-Hans")
        #expect(resolved(stored: nil, system: ["zh-CN"]) == "zh-Hans")
        #expect(resolved(stored: nil, system: ["zh"]) == "zh-Hans")
        #expect(resolved(stored: nil, system: ["zh-Hant-TW"]) == "zh-Hant")
        #expect(resolved(stored: nil, system: ["zh-TW", "en"]) == "zh-Hant")
        #expect(resolved(stored: nil, system: ["zh-HK"]) == "zh-Hant")
        #expect(resolved(stored: nil, system: ["zh-MO"]) == "zh-Hant")
        #expect(resolved(stored: nil, system: ["ja-JP"]) == "ja")
        #expect(resolved(stored: nil, system: ["fr", "ja"]) == "ja")
        #expect(resolved(stored: "zh-Hant", system: ["zh-Hans"]) == "zh-Hant")
        #expect(resolved(stored: "ja", system: ["en"]) == "ja")
        #expect(resolved(stored: nil, system: ["en-US", "zh-Hant"]) == "en")
        #expect(resolved(stored: nil, system: ["en-US"]) == "en")
        #expect(resolved(stored: "zh-Hans", system: ["zh-Hans"], tests: true) == "en")
        #expect(resolved(stored: "nope", system: ["fr"]) == "en")
    }

    /// Korean is not a case in the app. Shipping `ko` in the catalog is enough for `ko-KR` to select it.
    @Test func aLanguageThatIsOnlyInTheCatalogNeedsNoMatcher() {
        #expect(resolved(stored: nil, system: ["ko-KR"], available: installed + ["ko"]) == "ko")
        #expect(resolved(stored: "ko", system: ["en"], available: installed + ["ko"]) == "ko")
        #expect(AppLanguage(id: "ko").nativeName == "한국어")
    }

    @Test func menuUsesEachLanguagesOwnName() {
        #expect(AppLanguage(id: "en").nativeName == "English")
        #expect(AppLanguage(id: "zh-Hans").nativeName == "简体中文")
        #expect(AppLanguage(id: "zh-Hant").nativeName == "繁體中文")
        #expect(AppLanguage(id: "ja").nativeName == "日本語")
        #expect(AppLanguage(id: "zh-Hans").nativeName != AppLanguage(id: "zh-Hant").nativeName)
        #expect(AppLanguage.menu.first?.id == "en")
        #expect(Set(AppLanguage.menu.map(\.id)).isSuperset(of: Set(installed)))
    }

    @Test func aSharedNameIsSplitByScript() {
        #expect(AppLanguage.distinguished("中文", scriptName: "简体中文", collides: true) == "简体中文")
        #expect(AppLanguage.distinguished("简体中文", scriptName: "简体中文", collides: false) == "简体中文")
        #expect(AppLanguage.displayName(for: "zh-Hans", among: ["zh-Hans", "zh-Hant"]) == "简体中文")
    }

    @Test func preferenceRoundTripRemovesTheTestValue() {
        let defaults = UserDefaults.standard
        let key = AppLanguage.defaultsKey
        let previous = defaults.string(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set("zh-Hans", forKey: key)
        #expect(defaults.string(forKey: key) == "zh-Hans")
        #expect(resolved(stored: defaults.string(forKey: key), system: ["en"]) == "zh-Hans")
    }

    /// Blend modes stay the English token a project file stores, and English UI shows that same word.
    @Test func blendModeRawValueStaysEnglish() {
        #expect(LayerBlendMode.multiply.rawValue == "Multiply")
        #expect(LayerBlendMode.multiply.localizedTitle == "Multiply")
        #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
    }

    private func resolved(stored: String?, system: [String], available: [String]? = nil, tests: Bool = false) -> String {
        AppLanguage.resolved(stored: stored, systemLanguages: system, available: available ?? installed, isRunningTests: tests).id
    }
}
