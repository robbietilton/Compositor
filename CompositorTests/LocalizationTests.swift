import Foundation
import Testing
@testable import Compositor

/// Anchor for `Bundle(for:)` — the test bundle the raw `Localizable.xcstrings` is copied into by
/// the CompositorTests Resources phase (as `text.json`, so it stays JSON instead of compiling).
private final class LocalizationTestsAnchor {}

@MainActor
struct LocalizationTests {
    // MARK: Catalog completeness

    /// Every key in the string catalog must carry a non-empty Simplified Chinese translation —
    /// the deterministic guarantee the in-app language switcher depends on.
    @Test func simplifiedChineseCoversEveryCatalogKey() throws {
        let catalog = try loadCatalog()
        let entries = catalog.strings
        #expect(!entries.isEmpty, "the catalog should contain keys")

        let untranslated = entries.keys.filter { key in
            guard let value = entries[key]?.localizations?["zh-Hans"]?.stringUnit?.value else { return true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted()
        #expect(untranslated.isEmpty, "keys without a non-empty zh-Hans translation: \(untranslated.prefix(10))")
    }

    // MARK: Language switching

    /// The choice→`AppleLanguages` mapping: an explicit language pins the override list, "follow the
    /// system" clears it (`nil` → removed, not emptied).
    @Test func languageChoiceMapsToAppleLanguagesOverride() {
        #expect(UILanguage.appleLanguagesValue(for: .system) == nil)
        #expect(UILanguage.appleLanguagesValue(for: .english) == ["en"])
        #expect(UILanguage.appleLanguagesValue(for: .simplifiedChinese) == ["zh-Hans"])
    }

    /// Applying a choice writes the override and the remembered menu selection; switching back to
    /// "follow the system" removes `AppleLanguages` outright. Assertions read the suite's persistent
    /// domain: `AppleLanguages` also lives in the global domain, so a plain `object(forKey:)` would
    /// fall through to the system's language list and could never prove the override is gone.
    @Test func applyingLanguageWritesAndRemovesAppleLanguages() throws {
        let suiteName = "LocalizationTests.UILanguage"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func stored(_ key: String) -> Any? { defaults.persistentDomain(forName: suiteName)?[key] }

        UILanguage.apply(.english, to: defaults)
        #expect(stored("AppleLanguages") as? [String] == ["en"])
        #expect(stored(UILanguage.preferenceKey) as? String == "en")

        UILanguage.apply(.simplifiedChinese, to: defaults)
        #expect(stored("AppleLanguages") as? [String] == ["zh-Hans"])
        #expect(stored(UILanguage.preferenceKey) as? String == "zh-Hans")

        UILanguage.apply(.system, to: defaults)
        #expect(stored("AppleLanguages") == nil, "system must remove the override, not empty it")
        #expect(stored(UILanguage.preferenceKey) as? String == "system")
    }

    /// The raw values are what gets persisted; they must round-trip so `UILanguage.stored` can
    /// recover the menu selection.
    @Test func languageRawValuesRoundTripThroughStorage() {
        for language in UILanguage.allCases {
            #expect(UILanguage(rawValue: language.rawValue) == language)
        }
        #expect(UILanguage.allCases.map(\.rawValue).count == Set(UILanguage.allCases.map(\.rawValue)).count,
                "raw values must be unique to keep the stored preference unambiguous")
    }

    // MARK: Bundle loading

    /// The catalog JSON ships in the test bundle and parses as a string catalog.
    @Test func catalogJSONIsLoadableFromTheTestBundle() throws {
        let url = try #require(Bundle(for: LocalizationTestsAnchor.self).url(forResource: "Localizable", withExtension: "xcstrings"),
                               "Localizable.xcstrings must be copied into the test bundle as raw JSON")
        let object = try #require(try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["strings"] is [String: Any], "the catalog JSON must decode with a strings table")
    }

    /// The catalog must also survive compilation: the hosted app bundle exposes a zh-Hans
    /// localization whose compiled `Localizable` table Bundle can load, covering every source key.
    @Test func compiledCatalogLoadsThroughBundle() throws {
        let appBundle = try #require(hostAppBundle())
        #expect(appBundle.localizations.contains("zh-Hans"), "the app bundle must advertise zh-Hans")

        let table = try #require(appBundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "zh-Hans"),
                                 "the compiled zh-Hans Localizable table must exist in the app bundle")
        let compiled = try #require(NSDictionary(contentsOfFile: table) as? [String: String])
        #expect(!compiled.isEmpty)

        let catalog = try loadCatalog()
        let missing = catalog.strings.keys.filter { compiled[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }.sorted()
        #expect(missing.isEmpty, "keys the catalog declares but the compiled zh-Hans table lacks: \(missing.prefix(10))")
    }

    // MARK: Helpers

    private func loadCatalog() throws -> Catalog {
        let url = try #require(Bundle(for: LocalizationTestsAnchor.self).url(forResource: "Localizable", withExtension: "xcstrings"),
                               "Localizable.xcstrings must be copied into the test bundle as raw JSON")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    /// Tests run hosted in Compositor.app (`TEST_HOST`), so `Bundle.main` is the app the catalog
    /// compiles into; `allBundles` is the fallback if the harness ever runs them unhosted.
    private func hostAppBundle() -> Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }
        return Bundle.allBundles.first { $0.bundleURL.pathExtension == "app" }
    }
}

/// The slice of the `.xcstrings` format these tests assert on.
private struct Catalog: Decodable {
    let strings: [String: Entry]

    struct Entry: Decodable {
        let localizations: [String: Localization]?

        struct Localization: Decodable {
            let stringUnit: StringUnit?

            struct StringUnit: Decodable {
                let state: String?
                let value: String
            }
        }
    }
}
