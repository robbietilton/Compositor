import AppKit
import Testing
@testable import Compositor

@MainActor
struct CommandPaletteTests {
    private func entry(_ id: String, enabled: Bool = true) -> CommandPaletteEntry {
        CommandPaletteEntry(id: id, shortcut: nil, isEnabled: enabled, perform: {})
    }

    @Test func lettersInOrderMatchAndWordStartsCount() {
        #expect(CommandPaletteSearch.score("gb", in: "Filter › Gaussian Blur…") != nil)
        #expect(CommandPaletteSearch.score("BLUR", in: "Filter › Gaussian Blur…") != nil, "case doesn't matter")
        #expect(CommandPaletteSearch.score("bg", in: "Filter › Gaussian Blur…") == nil, "letters must come in order")
        #expect(CommandPaletteSearch.score("", in: "Anything") == 0)
        let wordStarts = CommandPaletteSearch.score("gb", in: "Filter › Gaussian Blur…")!
        let midWord = CommandPaletteSearch.score("gb", in: "Edit › Debug Tab")!
        #expect(wordStarts > midWord)
    }

    @Test func rankingPutsTheBestAndEnabledFirst() {
        let entries = [entry("Edit › Paste"), entry("Layer › Flip Layer Horizontal"),
                       entry("Filter › Gaussian Blur…"), entry("Filter › Motion Blur…"),
                       entry("Edit › Undo", enabled: false), entry("Image › Levels…")]
        #expect(CommandPaletteSearch.rank(entries, query: "gau").first?.id == "Filter › Gaussian Blur…")
        #expect(CommandPaletteSearch.rank(entries, query: "blur").map(\.id) == ["Filter › Gaussian Blur…", "Filter › Motion Blur…"]
                || CommandPaletteSearch.rank(entries, query: "blur").map(\.id) == ["Filter › Motion Blur…", "Filter › Gaussian Blur…"])
        #expect(CommandPaletteSearch.rank(entries, query: "fl").first?.id == "Layer › Flip Layer Horizontal")
        // No query: everything, enabled first, in menu order.
        let all = CommandPaletteSearch.rank(entries, query: "")
        #expect(all.count == entries.count && all.last?.id == "Edit › Undo" && all.first?.id == "Edit › Paste")
        #expect(CommandPaletteSearch.rank(entries, query: "e u").map(\.id).last == "Edit › Undo", "disabled after enabled")
    }

    final class Hits: NSObject {
        var count = 0
        @objc func hit(_ sender: Any?) { count += 1 }
    }

    /// A small main menu: the app menu, File (with a separator, a hidden item, a disabled item and a submenu),
    /// Window, and View holding the palette's own item.
    private func menuBar(_ hits: Hits) -> NSMenu {
        func item(_ title: String, key: String = "", mask: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Hits.hit(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = hits
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            items.forEach(submenu.addItem)
            holder.submenu = submenu
            return holder
        }
        let hidden = item("Hidden"); hidden.isHidden = true
        let disabled = item("Disabled"); disabled.isEnabled = false
        let main = NSMenu(title: "Main")
        main.addItem(menu("Compositor", [item("About Compositor")]))
        main.addItem(menu("File", [item("Save", key: "s", mask: .command), .separator(), hidden, disabled,
                                   menu("Open Recent", [item("Clear Menu")])]))
        main.addItem(menu("Window", [item("Minimize", key: "m", mask: .command)]))
        main.addItem(menu("View", [item("Command Palette…", key: "p", mask: [.command, .option])]))
        return main
    }

    @Test func menuBarBecomesEntries() throws {
        let hits = Hits()
        let bar = menuBar(hits) // Kept alive, as NSApp keeps its main menu: entries hold their menus weakly.
        let entries = CommandPaletteMenu.entries(in: bar, skipping: ["Window", "Command Palette…"])
        #expect(entries.map(\.id) == ["File › Save", "File › Disabled", "File › Open Recent › Clear Menu"])
        let save = try #require(entries.first)
        #expect(save.shortcut == "⌘S" && save.isEnabled)
        #expect(entries[1].isEnabled == false)
        save.perform()
        #expect(hits.count == 1, "running an entry sends its menu item's action")
    }

    @Test func shortcutsReadAsTheMenuShowsThem() {
        func label(_ key: String, _ mask: NSEvent.ModifierFlags) -> String? {
            let item = NSMenuItem(title: "x", action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            return CommandPaletteMenu.shortcut(of: item)
        }
        #expect(label("p", [.command, .option]) == "⌥⌘P")
        #expect(label("Z", [.command]) == "⇧⌘Z", "an uppercase key implies Shift")
        #expect(label("\u{8}", [.option]) == "⌥Delete")
        #expect(label("", [.command]) == nil)
    }

    @Test func toolsAreEntriesThatSelectTheTool() throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        let tools = CommandPaletteEntry.tools(for: session)
        #expect(tools.count == NavigationTool.allCases.count - 1)
        let brush = try #require(tools.first { $0.id == "Tool › \(NavigationTool.brush.label)" })
        brush.perform()
        #expect(session.tool == .brush)
    }

    @Test func modelMovesWithinResultsAndResetsOnTyping() {
        let model = CommandPaletteModel(entries: [entry("Edit › Paste"), entry("Filter › Gaussian Blur…"), entry("Image › Levels…")])
        model.move(by: -1)
        #expect(model.selected?.id == "Image › Levels…", "up from the top wraps to the bottom")
        model.move(by: 1)
        #expect(model.selected?.id == "Edit › Paste")
        model.move(by: 1)
        model.query = "lev"
        #expect(model.selection == 0 && model.selected?.id == "Image › Levels…")
        model.query = "zzz"
        #expect(model.selected == nil)
        model.move(by: 1)
        #expect(model.selection == 0)
    }

    @Test func paletteShortcutIsListedAndFree() throws {
        let definition = try #require(ShortcutDefinition.all.first { $0.title == "Command Palette" })
        #expect(definition.isMenu && definition.original == ShortcutChord("p", 3))
        #expect(ShortcutSettings.problem(in: [:]) == nil)
        #expect(CommandPaletteController.skipped.isSuperset(of: ["Command Palette…", "Window", "Help", "Services"]))
    }

    @Test func paletteOpensClosesAndRunsAfterClosing() async throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let controller = CommandPaletteController()
        controller.toggle(session: session, over: window, menu: NSMenu(title: "Empty"))
        #expect(controller.isOpen)
        var openWhenRun: Bool?
        controller.run(CommandPaletteEntry(id: "Test › Run", shortcut: nil, isEnabled: true, perform: { openWhenRun = controller.isOpen }))
        try await Task.sleep(for: .milliseconds(100))
        #expect(openWhenRun == false, "the palette is closed before the command runs")
        controller.toggle(session: session, over: window, menu: NSMenu(title: "Empty"))
        controller.toggle(session: session, over: window, menu: NSMenu(title: "Empty"))
        #expect(!controller.isOpen, "⌥⌘P again closes it")
        var ran = false
        controller.run(CommandPaletteEntry(id: "Test › Off", shortcut: nil, isEnabled: false, perform: { ran = true }))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ran, "a disabled entry never runs")
    }

    /// The View menu really has two items called "Snap": each must stay its own row, and run its own action.
    @Test func sameTitledItemsStayApart() throws {
        let first = Hits(), second = Hits()
        let view = NSMenu(title: "View")
        view.autoenablesItems = false
        for hits in [first, second] {
            let item = NSMenuItem(title: "Snap", action: #selector(Hits.hit(_:)), keyEquivalent: "")
            item.target = hits
            view.addItem(item)
        }
        let bar = NSMenu(title: "Main")
        bar.addItem(NSMenuItem(title: "Compositor", action: nil, keyEquivalent: ""))
        bar.items[0].submenu = NSMenu(title: "Compositor")
        let holder = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        holder.submenu = view
        bar.addItem(holder)
        let entries = CommandPaletteMenu.entries(in: bar, skipping: [])
        #expect(entries.map(\.title) == ["View › Snap", "View › Snap"])
        #expect(Set(entries.map(\.id)).count == 2, "distinct identities for the list")
        entries[1].perform()
        #expect(first.count == 0 && second.count == 1)
    }

    /// Against the app's own SwiftUI menu bar, not a hand-built one: its commands are listed, disabled ones greyed
    /// (SwiftUI takes their action away), and running one runs its SwiftUI action.
    @Test func realMenuBarRunsItsCommands() async throws {
        let bar = try #require(NSApp.mainMenu)
        func entries() -> [CommandPaletteEntry] { CommandPaletteMenu.entries(in: bar, skipping: CommandPaletteController.skipped) }
        func gridState() -> NSControl.StateValue? {
            bar.items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Pixel Grid (800% and above)" }?.state
        }
        let listed = entries()
        let titles = Set(listed.map(\.title))
        #expect(titles.contains("Filter › Gaussian Blur…") && !titles.contains("View › Command Palette…"))
        // The test host has no document open, so Zoom In is disabled: listed, greyed.
        let zoom = try #require(listed.first { $0.title == "View › Zoom In" })
        #expect(!zoom.isEnabled)
        let grid = try #require(listed.first { $0.title == "View › Pixel Grid (800% and above)" })
        let before = try #require(gridState())
        grid.perform()
        try await Task.sleep(for: .milliseconds(300))
        _ = entries() // Reading the menu again refreshes it, as opening the palette does.
        #expect(gridState() != before, "the toggle's SwiftUI binding flipped")
        grid.perform() // Put it back.
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func paletteHasNoWindowButtons() throws {
        let controller = CommandPaletteController()
        controller.toggle(session: EditorSession(), over: nil, menu: NSMenu(title: "Empty"))
        defer { controller.close() }
        let panel = try #require(controller.panel)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(panel.standardWindowButton(button)?.isHidden ?? true)
        }
    }
}
