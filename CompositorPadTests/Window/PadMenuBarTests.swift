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
        #expect(bar.titles == ["File", "Edit", "View", "Select", "Image", "Filter", "Layer", "Window", "Help"])
    }

    /// Edit holds the Mac's Cut, Copy, Copy Merged and Paste, then the fills; no Find, whose ⌘G, ⇧⌘G and ⌘E the
    /// Layer menu has on the Mac, and no Select All, which is Select › All.
    @Test func editIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let edit = try #require(bar.menu(titled: "Edit"))
        #expect(edit.commands.map(\.title) == ["Cut", "Copy", "Copy Merged", "Paste", "Fill with Foreground Color",
                                               "Fill with Background Color", "Clear Selection Pixels", "Content-Aware Fill…"])
        #expect(edit.commands.map(shortcut) == ["⌘X", "⌘C", "⇧⌘C", "⌘V", "⌥⌫", "⌘⌫", "", "⇧⌫"])
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

    /// Open Recent ends with Clear Menu, as on the Mac, dimmed when there's nothing to clear.
    @Test func openRecentEndsWithClearMenu() throws {
        let none = AppDelegate.recentItems(for: [])
        #expect(none.count == 1)
        let clear = try #require(none.last as? UICommand)
        #expect(clear.title == "Clear Menu" && clear.attributes.contains(.disabled))
        #expect(clear.action == #selector(EditorWindowController.clearRecentProjects(_:)))

        let project = CompositorDocument.projectsFolder.appending(path: "Harbor.comp")
        let some = AppDelegate.recentItems(for: [project])
        let projects = try #require(some.first as? UIMenu)
        #expect(projects.options.contains(.displayInline))
        #expect(projects.children.map(\.title) == ["Harbor"])
        #expect((some.last as? UICommand)?.title == "Clear Menu" && (some.last as? UICommand)?.attributes.contains(.disabled) == false)
    }

    /// A window with a 200 × 100 project of a gray layer, where every adjustment could be made.
    private func window() throws -> EditorWindowController {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let session = try #require(controller.activeTab?.session)
        session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        try #require(session.canAdjustColors)
        return controller
    }

    /// The Mac's adjustments, filters and other commands the iPad has no editor or dialog for yet are listed as on the
    /// Mac, with its titles and shortcuts, dimmed.
    @Test func whatTheIPadCantDoYetIsListedDimmed() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let image = try #require(bar.menu(titled: "Image"))
        #expect(image.children.flatMap { item -> [UIMenuElement] in
            switch item {
            case .menu(let menu): menu.children.compactMap { if case .element(let element) = $0 { element } else { nil } }
            case .element(let element): [element]
            }
        }.map(\.title) == ["Curves…", "Levels…", "Hue/Saturation…", "Black & White…", "Color Balance…", "Exposure…",
                           "Gradient Map…", "Grain…", "Invert", "Canvas Size…", "Image Size…", "Trim…"])
        let filter = try #require(bar.menu(titled: "Filter"))
        #expect(filter.commands.map(\.title) == ["Gaussian Blur…", "Motion Blur…", "Add Noise…", "Vignette…", "Bloom / Glow…",
                                                 "Dither…", "Tonal Contrast…", "Lens Correction…", "Camera Raw Filter…",
                                                 "Remove Background…"])
        let fill = try #require(bar.menu(titled: "Edit")?.commands.last)
        for command in filter.commands + image.commands.filter({ ["Black & White…", "Color Balance…", "Exposure…", "Gradient Map…",
                                                                  "Grain…"].contains($0.title) }) + [fill] {
            let action = command.action
            #expect(!controller.canPerformAction(action, withSender: command), "\(command.title)")
        }
        let select = try #require(bar.menu(titled: "Select"))
        let selectItems = select.children.flatMap { item -> [UIMenuElement] in
            if case .menu(let menu) = item { menu.children.compactMap { if case .element(let element) = $0 { element } else { nil } } } else { [] }
        }
        #expect(Array(selectItems.map(\.title).prefix(7)) == ["All", "Deselect", "Inverse", "Layer’s Pixels", "Subject", "Color Range…",
                                                             "Mask’s Black Areas"])
        let imageItems = image.children.flatMap { item -> [UIMenuElement] in
            switch item {
            case .menu(let menu): menu.children.compactMap { if case .element(let element) = $0 { element } else { nil } }
            case .element(let element): [element]
            }
        }
        let dimmed = (selectItems + imageItems).filter { ["Color Range…", "Trim…"].contains($0.title) }
        #expect(dimmed.count == 2 && dimmed.allSatisfy { ($0 as? UIAction)?.attributes.contains(.disabled) == true })
    }
}

