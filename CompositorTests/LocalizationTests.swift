import Foundation
import Testing
@testable import Compositor

struct LocalizationTests {
    @Test func supportedLanguagesHaveStableCodesAndNames() {
        #expect(AppLanguage.allCases == [.english, .simplifiedChinese])
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.english.displayName == "English")
        #expect(AppLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(AppLanguage.simplifiedChinese.displayName == "简体中文")
    }

    @Test func unknownLanguageFallsBackToEnglish() {
        #expect(AppLanguage.resolved(nil) == .english)
        #expect(AppLanguage.resolved("unsupported") == .english)
    }

    @Test func localizedResourcesContainBothLanguages() {
        #expect(L10n.string("Language", language: .english) == "Language")
        #expect(L10n.string("Language", language: .simplifiedChinese) == "语言")
        #expect(L10n.string("Gaussian Blur", language: .simplifiedChinese) == "高斯模糊")
    }
}
