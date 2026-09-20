import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func englishAndChineseLookupsAndFallback() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(L10n.string("New Canvas…", bundle: english) == "New Canvas…")
        #expect(L10n.string("New Canvas…", bundle: chinese) == "新建画布…")
        #expect(L10n.string("Multiply", bundle: chinese) == "正片叠底")
        #expect(L10n.string("Untranslated fallback", bundle: chinese) == "Untranslated fallback")
    }

    @Test func bothLanguagesHaveMatchingKeysAndFormatArguments() throws {
        func strings(_ language: String) throws -> [String: String] {
            let url = try #require(try bundle(language).url(forResource: "Localizable", withExtension: "strings"))
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try #require(plist as? [String: String])
        }
        let english = try strings("en"), chinese = try strings("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        let pattern = try NSRegularExpression(pattern: #"%\d+\$@"#)
        func arguments(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, translation) in chinese {
            #expect(!translation.isEmpty)
            #expect(arguments(key) == arguments(translation))
        }
    }

    @Test func formattedMessagesPreserveUserContent() throws {
        let name = "My 100% 图层 🌤"
        #expect(L10n.format("Save changes to %1$@?", name, bundle: try bundle("en")) == "Save changes to \(name)?")
        #expect(L10n.format("Save changes to %1$@?", name, bundle: try bundle("zh-Hans")) == "是否保存对“\(name)”的更改？")
        #expect(L10n.format("Current: %1$@ × %2$@ pixels", "1920", "1080", bundle: try bundle("zh-Hans")) == "当前：1920 × 1080 像素")
    }

    @Test func localizationDoesNotChangePersistedEnumValues() throws {
        #expect(LayerBlendMode.multiply.rawValue == "Multiply")
        #expect(LayerSampling.high.rawValue == "High quality")
        #expect(CanvasUnit.inches.rawValue == "Inches")
        for mode in LayerBlendMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(LayerBlendMode.self, from: data) == mode)
            #expect(String(data: data, encoding: .utf8) == "\"\(mode.rawValue)\"")
        }
    }

    @Test func translatedBlendMenuSelectsByIdentityInsteadOfTitle() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4, emptyLayer: true)
        let coordinator = BlendModePicker.Coordinator(session: session)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let chinese = try bundle("zh-Hans")
        button.addItems(withTitles: LayerBlendMode.allCases.map { L10n.string($0.rawValue, bundle: chinese) })
        let menu = try #require(button.menu)
        coordinator.menuWillOpen(menu)
        let index = try #require(LayerBlendMode.allCases.firstIndex(of: .multiply))
        button.selectItem(at: index)
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .multiply)
        #expect(button.titleOfSelectedItem == "正片叠底")
        coordinator.menuDidClose(menu)
    }
}
