import Foundation
import Testing
@testable import Compositor

@MainActor
struct LanguagePreferencesTests {
    private func isolated(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let domain = "Compositor.LanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults, domain)
    }

    @Test func defaultsFollowSystemWithoutWritingAnOverride() {
        isolated { defaults, domain in
            // A registered/inherited language is not an app-owned selection.
            defaults.register(defaults: ["AppleLanguages": ["zh-Hans"]])
            let preferences = LanguagePreferences(defaults: defaults, domainName: domain)
            #expect(preferences.selection == .system)
            #expect(!preferences.requiresRestart)
            #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        }
    }

    @Test func allChoicesPersistOnlyInTheSelectedDomain() {
        isolated { defaults, domain in
            let globalBefore = defaults.persistentDomain(forName: UserDefaults.globalDomain)
            defaults.setPersistentDomain(["unrelated": "keep me"], forName: domain)
            let preferences = LanguagePreferences(defaults: defaults, domainName: domain)
            for language in [ApplicationLanguage.english, .simplifiedChinese, .system] {
                preferences.select(language)
                let saved = defaults.persistentDomain(forName: domain)
                #expect(saved?["AppleLanguages"] as? [String] == language.preferredLanguages)
                #expect(saved?["unrelated"] as? String == "keep me")
                let reopened = LanguagePreferences(defaults: defaults, domainName: domain)
                #expect(reopened.selection == language)
                #expect(!reopened.requiresRestart)
            }
            #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:])
                .isEqual(to: globalBefore ?? [:]))
        }
    }

    @Test func restartNoticeComparesAgainstLaunchChoice() {
        isolated { defaults, domain in
            defaults.setPersistentDomain(["AppleLanguages": ["en"]], forName: domain)
            let preferences = LanguagePreferences(defaults: defaults, domainName: domain)
            preferences.select(.simplifiedChinese)
            #expect(preferences.requiresRestart)
            preferences.select(.english)
            #expect(!preferences.requiresRestart)
            preferences.select(.system)
            #expect(preferences.requiresRestart)
        }
    }

    @Test func invalidPreferenceFallsBackWithoutRewritingIt() {
        isolated { defaults, domain in
            for value in [["unknown-language"], [], "zh-Hans", 42] as [Any] {
                defaults.setPersistentDomain(["AppleLanguages": value, "other": 7], forName: domain)
                let before = defaults.persistentDomain(forName: domain)!
                let preferences = LanguagePreferences(defaults: defaults, domainName: domain)
                #expect(preferences.selection == .system)
                #expect(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!).isEqual(to: before))
            }
        }
    }

    @Test func languageNamesAndStoredIdentifiersStayStable() {
        #expect(ApplicationLanguage.allCases.map(\.rawValue) == ["system", "en", "zh-Hans"])
        #expect(ApplicationLanguage.english.title == "English")
        #expect(ApplicationLanguage.simplifiedChinese.title == "简体中文")
    }

    @Test func choosingALanguageDoesNotChangeDocumentOrOpaqueRecipe() throws {
        try isolated { defaults, domain in
            let session = EditorSession()
            session.createDocument(width: 4, height: 4)
            let document = session.document
            let history = session.history.undoCount
            let bytes = Data(#"{ "future" : "100% 中文", "schema": 99 }"#.utf8)
            let operation = CameraRawOperation(payload: bytes, schemaVersion: 99)
            let preferences = LanguagePreferences(defaults: defaults, domainName: domain)
            preferences.select(.simplifiedChinese)
            #expect(session.document == document)
            #expect(session.history.undoCount == history)
            let restored = try JSONDecoder().decode(CameraRawOperation.self, from: JSONEncoder().encode(operation))
            #expect(restored.payload == bytes)
            #expect(restored.pluginID == "compositor.camera-raw")
        }
    }
}
