import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct UILocalizationIdentityTests {
    @Test func blendModeSelectionAndPreviewUseRepresentedIdentityNotTranslatedTitles() throws {
        let session = EditorSession()
        session.createDocument(width: 16, height: 16)
        session.addBlankLayer()
        let coordinator = BlendModePicker.Coordinator(session: session)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let menu = try #require(button.menu)
        // A deliberate title collision also catches accidental selection by display text.
        for mode in [LayerBlendMode.normal, .darken] {
            let item = NSMenuItem(title: "本地化显示名称", action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        BlendModePicker.select(.darken, in: button)
        #expect(BlendModePicker.mode(for: button.selectedItem) == .darken)
        #expect(BlendModePicker.mode(for: NSMenuItem.separator()) == nil)
        coordinator.menuWillOpen(menu)
        coordinator.menu(menu, willHighlight: button.selectedItem)
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .darken)
        #expect(BlendModePicker.mode(for: button.selectedItem) == .darken)
        BlendModePicker.select(.normal, in: button)
        coordinator.menuWillOpen(menu)
        // No highlight: the selected item's stable identity is the fallback.
        coordinator.choose(button)
        #expect(session.activeLayer?.blendMode == .normal)
    }

    @Test func shortcutDisplayNeverChangesPersistedKeysOrCanonicalAssignmentLookup() throws {
        let definition = try #require(ShortcutDefinition.all.first { $0.title == "CMYK Proof Colors" })
        #expect(definition.group == "Menus")
        #expect(definition.id == "Menus:CMYK Proof Colors")
        #expect(definition.displayTitle == AppLocalization.string("CMYK Proof Colors"))
        #expect(definition.displayGroup == AppLocalization.string("Menus"))
        #expect(definition.matches(definition.displayTitle))
        #expect(definition.matches(definition.displayGroup))
        #expect(definition.matches("CMYK Proof Colors"))
        let suite = "UILocalizationIdentityTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults)
        settings.save([definition.id: ShortcutChord("y", 1)])
        let restored = ShortcutSettings(defaults: defaults)
        #expect(restored.assigned("CMYK Proof Colors") == KeyboardShortcut("y", modifiers: .command))
        #expect(restored.overrides.keys.contains("Menus:CMYK Proof Colors"))
        #expect(ShortcutDefinition.all.filter { $0.group == "Text Editing" }.allSatisfy { $0.id.hasPrefix("Text Editing:") })
    }

    @Test func commandPaletteExcludesSystemMenusByIdentityAndDispatchesCurrentLanguagePaths() throws {
        let root = NSMenu()
        root.autoenablesItems = false
        let app = NSMenuItem(title: "Compositor", action: nil, keyEquivalent: "")
        app.submenu = NSMenu()
        root.addItem(app)
        let systemMenu = NSMenu(title: "窗口")
        systemMenu.autoenablesItems = false
        systemMenu.addItem(withTitle: "最小化", action: nil, keyEquivalent: "")
        let systemItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        systemItem.submenu = systemMenu
        root.addItem(systemItem)
        let edit = NSMenu(title: "编辑")
        edit.autoenablesItems = false
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        root.addItem(editItem)
        let receiver = PaletteActionReceiver()
        let command = NSMenuItem(title: "执行命令", action: #selector(PaletteActionReceiver.run(_:)), keyEquivalent: "")
        command.target = receiver
        edit.addItem(command)
        // A custom command may share a system menu's localized name without being excluded.
        edit.addItem(withTitle: "窗口", action: nil, keyEquivalent: "")
        let entries = CommandPaletteMenu.entries(in: root, skipping: [], excluding: [systemMenu])
        #expect(!entries.contains { $0.title.contains("最小化") })
        #expect(entries.contains { $0.title == "编辑 › 窗口" })
        let entry = try #require(entries.first { $0.title == "编辑 › 执行命令" })
        #expect(CommandPaletteSearch.rank(entries, query: "执行").first?.id == entry.id)
        entry.perform()
        #expect(receiver.runs == 1)
    }
}

@MainActor
private final class PaletteActionReceiver: NSObject {
    var runs = 0
    @objc func run(_ sender: Any?) { runs += 1 }
}
