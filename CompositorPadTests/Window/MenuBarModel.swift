import UIKit
@testable import Compositor

/// The menu bar the app builds, as a menu builder tests can read: it starts from the system's main menu as iPadOS hands
/// it over, applies what `buildMenu` asks of it, turning away shortcuts that clash as UIKit does, and gives back the
/// menus in their order.
@MainActor final class MenuBarModel: NSObject, UIMenuBuilder {
    /// A menu in the bar, or in another menu, with what it holds now.
    @MainActor final class Menu {
        let identifier: UIMenu.Identifier
        let title: String
        let options: UIMenu.Options
        var children: [Item]
        init(identifier: UIMenu.Identifier, title: String, options: UIMenu.Options = [], children: [Item] = []) {
            self.identifier = identifier
            self.title = title
            self.options = options
            self.children = children
        }
        convenience init(_ menu: UIMenu) {
            self.init(identifier: menu.identifier, title: menu.title, options: menu.options, children: menu.children.map(Item.init))
        }
        /// The commands in it, in the order shown, those of inline menus and submenus included.
        var commands: [UICommand] {
            children.flatMap { item -> [UICommand] in
                switch item {
                case .menu(let menu): menu.commands
                case .element(let element): (element as? UICommand).map { [$0] } ?? []
                }
            }
        }
        /// Its submenus, inline ones left out.
        var submenus: [Menu] {
            children.compactMap { if case .menu(let menu) = $0 { menu } else { nil } }
                .flatMap { $0.options.contains(.displayInline) ? $0.submenus : [$0] }
        }
    }
    @MainActor enum Item {
        case menu(Menu)
        case element(UIMenuElement)
        init(_ element: UIMenuElement) {
            if let menu = element as? UIMenu { self = .menu(Menu(menu)) } else { self = .element(element) }
        }
    }

    /// A key command of the system's, as the main menu holds it.
    private static func key(_ title: String, _ input: String, _ flags: UIKeyModifierFlags = .command, _ action: String) -> Item {
        .element(UIKeyCommand(title: title, action: NSSelectorFromString(action), input: input, modifierFlags: flags))
    }
    private static func command(_ title: String, _ action: String) -> Item {
        .element(UICommand(title: title, action: NSSelectorFromString(action)))
    }
    private static func group(_ identifier: UIMenu.Identifier, _ children: [Item] = []) -> Item {
        .menu(Menu(identifier: identifier, title: "", options: .displayInline, children: children))
    }
    private static func menu(_ identifier: UIMenu.Identifier, _ title: String, _ children: [Item] = []) -> Item {
        .menu(Menu(identifier: identifier, title: title, children: children))
    }

    /// The bar as the system hands it to `buildMenu` on iPadOS (read from the iOS 27 simulator), before the app's
    /// changes.
    let bar = Menu(identifier: .root, title: "", children: [
        menu(.application, "Compositor", [
            group(.about), group(.preferences, [key("Compositor Settings…", ",", .command, "orderFrontPreferencesPanel:")]),
            menu(.services, "Services"), group(.hide), group(.quit),
        ]),
        menu(.file, "File", [
            group(.newItem),
            group(.open, [key("Open…", "o", .command, "open:"), menu(.openRecent, "Open Recent")]),
            group(.close, [key("Close", "w", .command, "performClose:")]),
            group(.document), group(.print),
        ]),
        menu(.edit, "Edit", [
            group(.undoRedo, [key("Undo", "z", .command, "undo:"), key("Redo", "z", [.command, .shift], "redo:")]),
            group(.standardEdit, [
                key("Cut", "x", .command, "cut:"), key("Copy", "c", .command, "copy:"), key("Paste", "v", .command, "paste:"),
                key("Paste and Match Style", "v", [.command, .alternate, .shift], "pasteAndMatchStyle:"),
                command("Delete", "delete:"), key("Select All", "a", .command, "selectAll:"),
            ]),
            menu(.find, "Find", [
                group(.findPanel, [
                    key("Find", "f", .command, "find:"), key("Find & Replace", "f", [.command, .alternate], "findAndReplace:"),
                    key("Find Next", "g", .command, "findNext:"), key("Find Previous", "g", [.command, .shift], "findPrevious:"),
                ]),
                key("Use Selection for Find", "e", .command, "useSelectionForFind:"),
            ]),
            menu(.spelling, "Spelling and Grammar"), menu(.substitutions, "Substitutions"),
            menu(.transformations, "Transformations"), menu(.speech, "Speech"),
        ]),
        menu(.format, "Format", [
            menu(.font, "Font", [
                group(.textStyle, [key("Bold", "b", .command, "toggleBoldface:"), key("Italic", "i", .command, "toggleItalics:"),
                                   key("Underline", "u", .command, "toggleUnderline:")]),
                group(.textSize, [key("Bigger", "+", .command, "increaseSize:"), key("Smaller", "-", .command, "decreaseSize:")]),
            ]),
            menu(.text, "Text", [
                group(.alignment, [key("Align Left", "{", .command, "alignLeft:"), key("Center", "|", .command, "alignCenter:"),
                                   command("Justify", "alignJustified:"), key("Align Right", "}", .command, "alignRight:")]),
            ]),
        ]),
        menu(.view, "View", [
            group(.toolbar, [command("Customize Toolbar…", "runToolbarCustomizationPalette:")]),
            group(.sidebar, [key("Show Sidebar", "s", [.command, .control], "toggleSidebar:")]),
            group(.fullscreen),
        ]),
        menu(.window, "Window", [group(.minimizeAndZoom), group(.bringAllToFront)]),
        menu(.help, "Help", [key("", "?", .command, "showHelp:")]),
    ])

    /// Shortcuts that `buildMenu` added and UIKit turned away, as it does, with the key the bar already had.
    private(set) var conflicts: [String] = []

    /// The menus of the bar, by title, in order.
    var titles: [String] { bar.submenus.map(\.title) }

    /// The bar's menu titled `title`.
    func menu(titled title: String) -> Menu? { bar.submenus.first { $0.title == title } }

    /// The bar as `delegate` builds it.
    static func built(by delegate: UIResponder) -> MenuBarModel {
        let model = MenuBarModel()
        delegate.buildMenu(with: model)
        return model
    }

    // MARK: Finding

    private func find(_ identifier: UIMenu.Identifier, in menu: Menu? = nil) -> (parent: Menu, index: Int, menu: Menu)? {
        let menu = menu ?? bar
        for (index, item) in menu.children.enumerated() {
            guard case .menu(let child) = item else { continue }
            if child.identifier == identifier { return (menu, index, child) }
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }

    // MARK: Conflicts

    /// The key commands in `items`, menus within included.
    private static func keys(in items: [Item]) -> [UIKeyCommand] {
        items.flatMap { item -> [UIKeyCommand] in
            switch item {
            case .menu(let menu): keys(in: menu.children)
            case .element(let element): (element as? UIKeyCommand).map { [$0] } ?? []
            }
        }
    }

    /// Whether `elements` may go in, leaving out `replaced`: UIKit turns away the whole insertion when one of its
    /// shortcuts is already in the bar.
    private func accepts(_ elements: [UIMenuElement], replacing replaced: Menu? = nil) -> Bool {
        func chord(_ key: UIKeyCommand) -> String { "\(key.modifierFlags.rawValue) \(key.input ?? "")" }
        let leaving = Set(replaced.map { Self.keys(in: $0.children).map(chord) } ?? [])
        let existing = Self.keys(in: bar.children).map(chord).filter { !leaving.contains($0) }
        let clashes = Self.keys(in: elements.map(Item.init)).filter { existing.contains(chord($0)) }
        conflicts += clashes.map { "\($0.title) (\(chord($0)))" }
        return clashes.isEmpty
    }

    // MARK: UIMenuBuilder

    var system: UIMenuSystem { .main }

    func menu(for identifier: UIMenu.Identifier) -> UIMenu? {
        find(identifier).map { UIMenu(title: $0.menu.title, identifier: identifier, options: $0.menu.options, children: []) }
    }
    func action(for identifier: UIAction.Identifier) -> UIAction? { nil }
    func __command(forAction action: Selector, propertyList: Any?) -> UICommand? { nil }

    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementMenu: UIMenu) {
        guard let found = find(replacedIdentifier), accepts([replacementMenu], replacing: found.menu) else { return }
        found.parent.children[found.index] = .menu(Menu(replacementMenu))
    }
    func replaceChildren(ofMenu parentIdentifier: UIMenu.Identifier, from childrenBlock: ([UIMenuElement]) -> [UIMenuElement]) {
        guard let found = find(parentIdentifier) else { return }
        let children = childrenBlock([])
        guard accepts(children, replacing: found.menu) else { return }
        found.menu.children = children.map(Item.init)
    }
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementElements: [UIMenuElement]) {
        guard let found = find(replacedIdentifier), accepts(replacementElements, replacing: found.menu) else { return }
        found.parent.children.replaceSubrange(found.index...found.index, with: replacementElements.map(Item.init))
    }
    func replace(action replacedIdentifier: UIAction.Identifier, with replacementElements: [UIMenuElement]) {}
    func __replaceCommand(forAction replacedAction: Selector, propertyList replacedPropertyList: Any?,
                          with replacementElements: [UIMenuElement]) {}

    func insertSibling(_ siblingMenu: UIMenu, beforeMenu siblingIdentifier: UIMenu.Identifier) {
        insertElements([siblingMenu], beforeMenu: siblingIdentifier)
    }
    func insertSibling(_ siblingMenu: UIMenu, afterMenu siblingIdentifier: UIMenu.Identifier) {
        insertElements([siblingMenu], afterMenu: siblingIdentifier)
    }
    func insertElements(_ insertedElements: [UIMenuElement], beforeMenu siblingIdentifier: UIMenu.Identifier) {
        guard let found = find(siblingIdentifier), accepts(insertedElements) else { return }
        found.parent.children.insert(contentsOf: insertedElements.map(Item.init), at: found.index)
    }
    func insertElements(_ insertedElements: [UIMenuElement], afterMenu siblingIdentifier: UIMenu.Identifier) {
        guard let found = find(siblingIdentifier), accepts(insertedElements) else { return }
        found.parent.children.insert(contentsOf: insertedElements.map(Item.init), at: found.index + 1)
    }
    func insertChild(_ childMenu: UIMenu, atStartOfMenu parentIdentifier: UIMenu.Identifier) {
        insertElements([childMenu], atStartOfMenu: parentIdentifier)
    }
    func insertChild(_ childMenu: UIMenu, atEndOfMenu parentIdentifier: UIMenu.Identifier) {
        insertElements([childMenu], atEndOfMenu: parentIdentifier)
    }
    func insertElements(_ childElements: [UIMenuElement], atStartOfMenu parentIdentifier: UIMenu.Identifier) {
        guard accepts(childElements) else { return }
        find(parentIdentifier)?.menu.children.insert(contentsOf: childElements.map(Item.init), at: 0)
    }
    func insertElements(_ childElements: [UIMenuElement], atEndOfMenu parentIdentifier: UIMenu.Identifier) {
        guard accepts(childElements) else { return }
        find(parentIdentifier)?.menu.children.append(contentsOf: childElements.map(Item.init))
    }
    func insertElements(_ insertedElements: [UIMenuElement], beforeAction siblingIdentifier: UIAction.Identifier) {}
    func insertElements(_ insertedElements: [UIMenuElement], afterAction siblingIdentifier: UIAction.Identifier) {}
    func __insert(_ insertedElements: [UIMenuElement], beforeCommandForAction siblingAction: Selector, propertyList: Any?) {}
    func __insert(_ insertedElements: [UIMenuElement], afterCommandForAction siblingAction: Selector, propertyList: Any?) {}

    func remove(menu removedIdentifier: UIMenu.Identifier) {
        guard let found = find(removedIdentifier) else { return }
        found.parent.children.remove(at: found.index)
    }
    func remove(action removedIdentifier: UIAction.Identifier) {}
    func __removeCommand(forAction removedAction: Selector, propertyList: Any?) {}
}
