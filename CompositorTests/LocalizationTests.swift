import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    @Test func languagePreferencePersistsAndSystemRemovesOverride() throws {
        let suite = "CompositorLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppLanguage.selected(in: defaults) == .system)
        AppLanguage.simplifiedChinese.save(in: defaults)
        #expect(AppLanguage.selected(in: defaults) == .simplifiedChinese)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])
        AppLanguage.english.save(in: defaults)
        #expect(AppLanguage.selected(in: defaults) == .english)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["en"])
        AppLanguage.system.save(in: defaults)
        #expect(AppLanguage.selected(in: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        defaults.set("not-a-supported-language", forKey: "appLanguage")
        #expect(AppLanguage.selected(in: defaults) == .system)
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func chineseAndEnglishResourcesHaveIdenticalKeysAndValidPlaceholders() throws {
        let english = try bundle("en"), chinese = try bundle("zh-Hans")
        func strings(_ bundle: Bundle) throws -> [String: String] {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let data = try Data(contentsOf: url)
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let source = try strings(english), translated = try strings(chinese)
        #expect(Set(source.keys) == Set(translated.keys))
        #expect(source.count > 1000)
        let placeholders = try NSRegularExpression(pattern: "%(@|lld|ll[doux]|[duf])")
        func formats(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }
        }
        for (key, value) in source {
            let translation = try #require(translated[key])
            #expect(formats(value) == formats(translation), "Invalid placeholders for \(key)")
            #expect(translation.isEmpty == value.isEmpty, "Empty translation for \(key)")
        }
        #expect(L10n.string("Language", bundle: chinese) == "语言")
        #expect(L10n.string("Save", bundle: english) == "Save")
        #expect(L10n.string("A future untranslated string", bundle: chinese) == "A future untranslated string")
        #expect(String(format: L10n.string("Save changes to %@?", bundle: chinese), "Travel.comp") == "要保存对 Travel.comp 的更改吗？")
    }

    @Test func translatedBlendModeMenuKeepsStableModelValues() throws {
        let chinese = try bundle("zh-Hans")
        #expect(L10n.string(LayerBlendMode.multiply.rawValue, bundle: chinese) == "正片叠底")
        for mode in LayerBlendMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(LayerBlendMode.self, from: encoded) == mode)
            #expect(LayerBlendMode(rawValue: L10n.string(mode.rawValue, bundle: chinese)) == nil)
        }
    }

    @Test func chineseCommandSearchFindsTranslatedTitles() {
        let entry = CommandPaletteEntry(id: "Tool › Brush", title: "工具 › 画笔", shortcut: "B", isEnabled: true, perform: {})
        #expect(CommandPaletteSearch.rank([entry], query: "画笔").first?.id == entry.id)
    }
}
