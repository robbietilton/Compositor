import Testing
import UIKit
@testable import Compositor

/// The menu bar, laid out as the Mac's.
@MainActor struct PadMenuBarTests {
    private func shortcut(_ command: UICommand) -> String {
        guard let key = command as? UIKeyCommand, let input = key.input else { return "" }
        let flags = key.modifierFlags
        let name = input == UIKeyCommand.inputDelete ? "⌫" : input.uppercased()
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.alternate) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + name
    }

    /// The app's menus come after View, in the Mac's order.
    @Test func theMenusComeInTheMacsOrder() {
        let bar = MenuBarModel.built(by: AppDelegate())
        #expect(bar.titles == ["File", "Edit", "View", "Select", "Image", "Layer", "Window", "Help"])
    }

    /// Edit holds the Mac's Cut, Copy, Copy Merged and Paste, then the fills; no Find, whose ⌘G, ⇧⌘G and ⌘E the
    /// Layer menu has on the Mac, and no Select All, which is Select › All.
    @Test func editIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let edit = try #require(bar.menu(titled: "Edit"))
        #expect(edit.commands.map(\.title) == ["Cut", "Copy", "Copy Merged", "Paste", "Fill with Foreground Color",
                                               "Fill with Background Color", "Clear Selection Pixels"])
        #expect(edit.commands.map(shortcut) == ["⌘X", "⌘C", "⇧⌘C", "⌘V", "⌥⌫", "⌘⌫", ""])
        #expect(edit.submenus.isEmpty)
    }

    /// Select › All has ⌘A, as on the Mac, and goes to whichever responds first: a field being edited, or the canvas.
    @Test func selectAllHasCommandA() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let all = try #require(bar.menu(titled: "Select")?.commands.first)
        #expect(all.title == "All" && shortcut(all) == "⌘A")
        #expect(all.action == #selector(UIResponderStandardEditActions.selectAll(_:)))
    }

    /// File's exports are a group of their own, between the saves and Close, as on the Mac.
    @Test func theExportsAreAGroupOfTheirOwn() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let file = try #require(bar.menu(titled: "File"))
        let groups = file.children.compactMap { item -> [String]? in
            guard case .menu(let menu) = item, menu.options.contains(.displayInline) else { return nil }
            return menu.commands.map(\.title)
        }
        #expect(groups.contains(["Save", "Duplicate", "Rename…"]))
        #expect(groups.contains(["Export PNG…", "Export JPEG…"]))
    }

    /// New Canvas… opens a form, as the Mac's does.
    @Test func newCanvasHasAnEllipsis() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        #expect(bar.menu(titled: "File")?.commands.first?.title == "New Canvas…")
    }

    /// No two of the app's shortcuts are the same keys.
    @Test func noTwoShortcutsAreTheSame() {
        let bar = MenuBarModel.built(by: AppDelegate())
        let menuKeys = bar.bar.commands.compactMap { $0 as? UIKeyCommand }
        let windowKeys = EditorWindowController().keyCommands ?? []
        var seen: [String: String] = [:]
        for key in menuKeys + windowKeys {
            guard let input = key.input else { continue }
            let chord = "\(key.modifierFlags.rawValue) \(input)"
            #expect(seen[chord] == nil, "\(key.title) and \(seen[chord] ?? "") are both \(shortcut(key))")
            seen[chord] = key.title
        }
    }
}
