import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct LocalizationTests {
    @Test func chineseResourcesPreserveFormatArguments() throws {
        for language in ["zh-Hans", "zh-Hant", "zh"] {
            let path = try #require(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            let strings = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(strings["New Canvas…"] == "新建画布…")
            for (key, value) in strings where key.contains("%@") {
                #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count)
            }
            #expect(String(format: try #require(strings["Save changes to %@?"]), "Photo.comp") == "要保存对 Photo.comp 的更改吗？")
        }
        #expect(L10n.format("%@%%", "80") == "80%")
        #expect(L10n.text("A user-created project name") == "A user-created project name")
    }

    @Test func translatedBlendModeTitlesKeepTheirModelIdentity() throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8, emptyLayer: true)
        _ = try #require(session.activeLayerID)
        let host = NSHostingView(rootView: BlendModePicker(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        host.layoutSubtreeIfNeeded()
        func findButton(_ view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton { return button }
            return view.subviews.lazy.compactMap(findButton).first
        }
        let button = try #require(findButton(host))
        let menu = try #require(button.menu)
        for mode in LayerBlendMode.allCases {
            let item = try #require(button.itemArray.first { $0.representedObject as? String == mode.rawValue })
            #expect(item.title == L10n.text(mode.rawValue))
            menu.delegate?.menuWillOpen?(menu)
            button.select(item)
            button.sendAction(button.action, to: button.target)
            #expect(session.activeLayer?.blendMode == mode)
            menu.delegate?.menuDidClose?(menu)
        }
    }

    private final class CommandTarget: NSObject {
        var invocations = 0
        @objc func run(_ sender: Any?) { invocations += 1 }
    }

    @Test func commandPaletteSearchesAndRunsLocalizedMenuEntries() throws {
        let target = CommandTarget()
        let bar = NSMenu()
        let appItem = NSMenuItem(title: "Compositor", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu()
        bar.addItem(appItem)
        let filter = NSMenuItem(title: L10n.text("Filter"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        filter.submenu = submenu
        bar.addItem(filter)
        let query = L10n.text("Gaussian Blur")
        let command = NSMenuItem(title: query + "…", action: #selector(CommandTarget.run(_:)), keyEquivalent: "")
        command.target = target
        submenu.addItem(command)
        let listed = CommandPaletteMenu.entries(in: bar, skipping: [])
        let match = try #require(CommandPaletteSearch.rank(listed, query: query).first)
        #expect(match.title.hasSuffix(query + "…"))
        match.perform()
        #expect(target.invocations == 1)
    }
}
