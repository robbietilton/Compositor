import AppKit
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    private func chineseBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func compiledChineseResourcesKeepFormatArguments() throws {
        let bundle = try chineseBundle()
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        #expect(strings.count > 1_000)
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp])"#)
        func parameters(_ text: String) -> [String] {
            let source = text.replacingOccurrences(of: "%%", with: "") as NSString
            return regex.matches(in: source as String, range: NSRange(location: 0, length: source.length))
                .enumerated().map { index, match in
                    let position = match.range(at: 1).location == NSNotFound ? "\(index + 1)" : source.substring(with: match.range(at: 1))
                    let length = match.range(at: 2).location == NSNotFound ? "" : source.substring(with: match.range(at: 2))
                    return position + ":" + length + source.substring(with: match.range(at: 3))
                }.sorted()
        }
        for (key, value) in strings {
            #expect(!value.isEmpty, "Missing Chinese value: \(key)")
            #expect(parameters(key) == parameters(value), "Format arguments changed: \(key)")
        }
        #expect(bundle.localizedString(forKey: "Multiply", value: nil, table: nil) == "正片叠底")
        #expect(String(localized: "Layer \(3)", bundle: bundle) == "图层 3")
    }

    @Test func translatedBlendTitlesKeepSelectionAndPreviewIdentity() throws {
        let bundle = try chineseBundle()
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.addBlankLayer()
        let coordinator = BlendModePicker.Coordinator(session: session)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in LayerBlendMode.allCases {
            button.addItem(withTitle: bundle.localizedString(forKey: mode.rawValue, value: nil, table: nil))
            button.lastItem?.representedObject = mode.rawValue
        }
        let menu = try #require(button.menu)
        for (index, mode) in LayerBlendMode.allCases.enumerated() {
            coordinator.menuWillOpen(menu)
            coordinator.menu(menu, willHighlight: button.item(at: index))
            #expect(session.displayedBlendMode(for: try #require(session.activeLayer)) == mode)
            button.selectItem(at: index)
            coordinator.choose(button)
            #expect(session.activeLayer?.blendMode == mode)
            #expect(session.projectSnapshot()?.manifest.layers.last?.blendMode == mode)
        }
        #expect(LayerBlendMode.multiply.rawValue == "Multiply")
    }

    @Test func chineseCommandSearchRunsTheSelectedAction() {
        var ran = false
        let entries = [CommandPaletteEntry(id: "图像 › 色阶…", shortcut: nil, isEnabled: true, perform: { ran = true }),
                       CommandPaletteEntry(id: "图层 › 新建图层", shortcut: nil, isEnabled: true, perform: {})]
        let model = CommandPaletteModel(entries: entries)
        model.query = "色阶"
        #expect(model.results.count == 1)
        model.selected?.perform()
        #expect(ran)
        #expect(ShortcutChord("w", 0).label == "W")
        #expect(ShortcutChord("h", 0).label == "H")
    }

    @Test func languagePreferenceChangesOnlyTheRequestedDefaults() throws {
        let suite = "CompositorLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated")
        #expect(LanguagePreference.save("zh-Hans", defaults: defaults))
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        #expect(!LanguagePreference.save("invalid", defaults: defaults))
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        #expect(LanguagePreference.save("en", defaults: defaults))
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        #expect(LanguagePreference.save(nil, defaults: defaults))
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }
}
