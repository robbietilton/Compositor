import UIKit
@testable import Compositor

/// The menu bar the app builds, as a menu builder tests can read: it starts from the parts of the system's main menu the
/// app works with, applies what `buildMenu` asks of it, and gives back the menus in their order.
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

    /// The bar: the system's File, Edit, Format, View, Window and Help, with Edit's undo, standard and find groups.
    let bar = Menu(identifier: .root, title: "", children: [
        .menu(Menu(identifier: .file, title: "File", children: [.menu(Menu(identifier: .close, title: "", options: .displayInline))])),
        .menu(Menu(identifier: .edit, title: "Edit", children: [
            .menu(Menu(identifier: .undoRedo, title: "", options: .displayInline)),
            .menu(Menu(identifier: .standardEdit, title: "", options: .displayInline, children: [
                .element(UIKeyCommand(title: "Cut", action: #selector(UIResponderStandardEditActions.cut(_:)), input: "x", modifierFlags: .command)),
                .element(UIKeyCommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:)), input: "c", modifierFlags: .command)),
                .element(UIKeyCommand(title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:)), input: "v", modifierFlags: .command)),
                .element(UICommand(title: "Delete", action: #selector(UIResponderStandardEditActions.delete(_:)))),
                .element(UIKeyCommand(title: "Select All", action: #selector(UIResponderStandardEditActions.selectAll(_:)), input: "a",
                                      modifierFlags: .command)),
            ])),
            .menu(Menu(identifier: .find, title: "Find", children: [
                .element(UIKeyCommand(title: "Find…", action: NSSelectorFromString("find:"), input: "f", modifierFlags: .command)),
                .element(UIKeyCommand(title: "Find Next", action: NSSelectorFromString("findNext:"), input: "g", modifierFlags: .command)),
            ])),
        ])),
        .menu(Menu(identifier: .format, title: "Format")),
        .menu(Menu(identifier: .view, title: "View")),
        .menu(Menu(identifier: .window, title: "Window")),
        .menu(Menu(identifier: .help, title: "Help")),
    ])

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

    // MARK: UIMenuBuilder

    var system: UIMenuSystem { .main }

    func menu(for identifier: UIMenu.Identifier) -> UIMenu? {
        find(identifier).map { UIMenu(title: $0.menu.title, identifier: identifier, options: $0.menu.options, children: []) }
    }
    func action(for identifier: UIAction.Identifier) -> UIAction? { nil }
    func __command(forAction action: Selector, propertyList: Any?) -> UICommand? { nil }

    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementMenu: UIMenu) {
        guard let found = find(replacedIdentifier) else { return }
        found.parent.children[found.index] = .menu(Menu(replacementMenu))
    }
    func replaceChildren(ofMenu parentIdentifier: UIMenu.Identifier, from childrenBlock: ([UIMenuElement]) -> [UIMenuElement]) {
        guard let found = find(parentIdentifier) else { return }
        found.menu.children = childrenBlock([]).map(Item.init)
    }
    func replace(menu replacedIdentifier: UIMenu.Identifier, with replacementElements: [UIMenuElement]) {
        guard let found = find(replacedIdentifier) else { return }
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
        guard let found = find(siblingIdentifier) else { return }
        found.parent.children.insert(contentsOf: insertedElements.map(Item.init), at: found.index)
    }
    func insertElements(_ insertedElements: [UIMenuElement], afterMenu siblingIdentifier: UIMenu.Identifier) {
        guard let found = find(siblingIdentifier) else { return }
        found.parent.children.insert(contentsOf: insertedElements.map(Item.init), at: found.index + 1)
    }
    func insertChild(_ childMenu: UIMenu, atStartOfMenu parentIdentifier: UIMenu.Identifier) {
        insertElements([childMenu], atStartOfMenu: parentIdentifier)
    }
    func insertChild(_ childMenu: UIMenu, atEndOfMenu parentIdentifier: UIMenu.Identifier) {
        insertElements([childMenu], atEndOfMenu: parentIdentifier)
    }
    func insertElements(_ childElements: [UIMenuElement], atStartOfMenu parentIdentifier: UIMenu.Identifier) {
        find(parentIdentifier)?.menu.children.insert(contentsOf: childElements.map(Item.init), at: 0)
    }
    func insertElements(_ childElements: [UIMenuElement], atEndOfMenu parentIdentifier: UIMenu.Identifier) {
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
