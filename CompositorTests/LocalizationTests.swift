import Foundation
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    @Test func englishAndRussianCatalogsHaveTheSameNonEmptyKeys() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Compositor/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let strings = object["strings"] as! [String: Any]
        for (key, value) in strings {
            let localizations = (value as! [String: Any])["localizations"] as! [String: Any]
            #expect(localizations["en"] != nil, "Missing English localization for \(key)")
            #expect(localizations["ru"] != nil, "Missing Russian localization for \(key)")
        }
    }

    @Test func appLanguageUsesStableRawValues() {
        #expect(AppLanguage.system.rawValue == "system")
        #expect(AppLanguage.english.rawValue == "english")
        #expect(AppLanguage.russian.rawValue == "russian")
    }

    @Test func appLanguageStorePersistsAndRestoresSelection() {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppLanguageStore(defaults: defaults, systemLocale: Locale(identifier: "en_US"))
        first.selection = .russian
        let second = AppLanguageStore(defaults: defaults, systemLocale: Locale(identifier: "en_US"))
        #expect(second.selection == .russian)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func appLanguageStoreConfiguresNativeMenuLanguageForNextLaunch() {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AppLanguageStore(defaults: defaults, systemLocale: Locale(identifier: "ru_RU"))

        store.selection = .english
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        store.selection = .russian
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ru"])

        store.selection = .system
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func appLanguageResolvesSupportedAndFallbackLocales() {
        #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "ru_RU"), initial: .system).locale.identifier.hasPrefix("ru"))
        #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "de_DE"), initial: .system).locale.identifier.hasPrefix("en"))
        #expect(AppLanguageStore(defaults: .standard, systemLocale: Locale(identifier: "en_US"), initial: .russian).locale.identifier.hasPrefix("ru"))
    }

    @Test func representativeCatalogKeysRenderInRussianAndEnglish() {
        #expect(L10n.text("settings.language", locale: Locale(identifier: "ru")) == "Язык")
        #expect(L10n.text("settings.open", locale: Locale(identifier: "en")) == "Settings…")
        #expect(L10n.text("settings.open", locale: Locale(identifier: "ru")) == "Настройки…")
        #expect(L10n.text("menu.edit.undo", locale: Locale(identifier: "ru")) == "Отменить")
        #expect(L10n.text("menu.edit.undo", locale: Locale(identifier: "en")) == "Undo")
        #expect(L10n.text("unknown.localization.key", locale: Locale(identifier: "ru")) == "unknown.localization.key")
    }

    @Test func enumDisplayNamesDoNotChangeSerializedValues() {
        #expect(LayerBlendMode.normal.rawValue == "Normal")
        #expect(LayerBlendMode.colorDodge.rawValue == "Color Dodge")
        #expect(FilterKind.contentAwareFill.rawValue == "Content-Aware Fill")
        #expect(AdjustmentKind.hsv.rawValue == "Hue/Saturation")
    }

    @Test func russianEnumDisplayNamesUseAdobeTerminology() {
        let ru = Locale(identifier: "ru")
        #expect(LayerBlendMode.normal.localizedName(locale: ru) == "Обычный")
        #expect(LayerBlendMode.multiply.localizedName(locale: ru) == "Умножение")
        #expect(FilterKind.contentAwareFill.localizedName(locale: ru) == "Заливка с учетом содержимого")
        #expect(AdjustmentKind.hsv.localizedName(locale: ru) == "Цветовой тон/Насыщенность")
    }

    @Test func generatedLabelsAndSystemMessagesUseSelectedLocale() {
        let ru = Locale(identifier: "ru")
        #expect(L10n.numbered("Layer", number: 2, locale: ru) == "Слой 2")
        let definition = ShortcutDefinition(title: "Nudge Left 10 px", group: "Canvas & Layers", original: ShortcutChord("←"))
        #expect(definition.localizedTitle(locale: ru) == "Сместить влево на 10 пкс")
        #expect(L10n.text("liveMask.message.single", locale: ru) == "Этот слой является источником динамической маски")
    }
}
