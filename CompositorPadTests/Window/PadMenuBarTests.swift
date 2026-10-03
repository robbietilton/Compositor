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
        #expect(bar.titles == ["Compositor", "File", "Edit", "View", "Select", "Image", "Filter", "Layer", "Window", "Help"])
    }

    /// No shortcut of the app's is one iPadOS keeps for itself, which would never reach it: the Mac's ⌘H and ⌘M go
    /// without on iPad, as Home and Minimize there.
    @Test func noShortcutIsTheSystems() {
        let bar = MenuBarModel.built(by: AppDelegate())
        let keys = bar.bar.commands.compactMap { $0 as? UIKeyCommand } + (EditorWindowController().keyCommands ?? [])
        for key in keys {
            let reserved = MenuBarModel.reserved.first { $0.input == key.input && $0.flags == key.modifierFlags }
            #expect(reserved == nil, "\(key.title) is \(shortcut(key)), which iPadOS keeps for \(reserved?.what ?? "")")
        }
    }

    /// No shortcut the app adds clashes with one already in the system's menus, which UIKit would turn away, and with
    /// it the whole group it came in.
    @Test func noShortcutIsTurnedAway() {
        let bar = MenuBarModel.built(by: AppDelegate())
        #expect(bar.conflicts.isEmpty, "\(bar.conflicts)")
    }

    /// File is the Mac's: New Canvas…, Open Project… and Open Recent in place of the system's Open…, the imports, the
    /// saves, the exports, then Close Tab.
    @Test func theFileMenuIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let file = try #require(bar.menu(titled: "File"))
        #expect(file.commands.map(\.title) == ["New Canvas…", "Open Project…", "Import Images…", "Import from Photos…", "Save",
                                               "Duplicate", "Rename…", "Export PNG…", "Export JPEG…", "Close Tab"])
        #expect(file.commands.map(shortcut) == ["⌘N", "⌘O", "", "", "⌘S", "⇧⌘S", "", "⇧⌘E", "⌥⇧⌘S", "⌘W"])
        #expect(file.submenus.map(\.title) == ["Open Recent"])
    }

    /// Edit holds the Mac's Cut, Copy, Copy Merged and Paste, then the fills; no Find, whose ⌘G, ⇧⌘G and ⌘E the
    /// Layer menu has on the Mac, and no Select All, which is Select › All.
    @Test func editIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let edit = try #require(bar.menu(titled: "Edit"))
        #expect(edit.commands.map(\.title) == ["Undo", "Redo", "Cut", "Copy", "Copy Merged", "Paste", "Fill with Foreground Color",
                                               "Fill with Background Color", "Clear Selection Pixels", "Content-Aware Fill…"])
        #expect(edit.commands.map(shortcut) == ["⌘Z", "⇧⌘Z", "⌘X", "⌘C", "⇧⌘C", "⌘V", "⌥⌫", "⌘⌫", "", "⇧⌫"])
        #expect(!edit.submenus.map(\.title).contains("Find"))
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
                           "Gradient Map…", "Grain…", "Invert", "Canvas Size…", "Image Size…", "Trim…",
                           "Flip Canvas Horizontal", "Flip Canvas Vertical"])
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

    // MARK: Layer

    /// The Layer menu is the Mac's, with its titles and shortcuts, after the adjustment layers it offers.
    @Test func theLayerMenuIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let layer = try #require(bar.menu(titled: "Layer"))
        #expect(layer.submenus.map(\.title) == ["New Adjustment Layer"])
        let commands = Array(layer.commands.dropFirst(AdjustmentKind.allCases.count))
        #expect(commands.map(\.title) == ["Edit Adjustment…", "Transform Layer", "Duplicate Layer", "Create Clipping Mask",
                                          "Group Selected Layers", "Ungroup Layers", "Move Out of Folder", "New Blank Layer",
                                          "Rename Layer…", "Hide Layer", "Move Layer Up", "Move Layer Down", "Merge Down",
                                          "Flip Layer Horizontal", "Flip Layer Vertical", "Delete Layer"])
        #expect(commands.map(shortcut) == ["", "⌘T", "⌘J", "⌥⌘G", "⌘G", "⇧⌘G", "", "⇧⌘N", "", "", "⌘]", "⌘[", "⌘E", "", "", ""])
    }

    /// The bar's command titled `title` in the menu titled `menu`.
    private func command(_ title: String, in menu: String, of bar: MenuBarModel) throws -> UICommand {
        try #require(bar.menu(titled: menu)?.commands.first { $0.title == title }, "\(menu) › \(title)")
    }

    /// The title `command` shows now, as the window names it for what it will do.
    private func title(of command: UICommand, in controller: EditorWindowController) throws -> String {
        let shown = try #require(command.copy() as? UICommand)
        controller.validate(shown)
        return shown.title
    }

    /// Whether the window takes `command` now.
    private func takes(_ command: UICommand, in controller: EditorWindowController) -> Bool {
        controller.canPerformAction(command.action, withSender: command)
    }

    /// Chooses `command`, as the menu bar does once the window takes it.
    private func choose(_ command: UICommand, in controller: EditorWindowController) {
        #expect(takes(command, in: controller), "\(command.title)")
        guard takes(command, in: controller) else { return }
        controller.perform(command.action, with: command)
    }

    /// The Layer menu arranges layers as the Mac's does, each command only when it can, and named for what it will do.
    @Test func theLayerMenuArrangesLayers() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        // The new project's empty layer, and the gray one over it.
        let gray = try #require(session.document?.layers.first?.id)
        let top = try #require(session.activeLayerID)
        try #require(session.document?.layers.map(\.id) == [gray, top])

        let up = try command("Move Layer Up", in: "Layer", of: bar)
        let down = try command("Move Layer Down", in: "Layer", of: bar)
        #expect(!takes(up, in: controller))
        choose(down, in: controller)
        #expect(session.document?.layers.map(\.id) == [top, gray])
        #expect(!takes(down, in: controller))
        choose(up, in: controller)
        #expect(session.document?.layers.map(\.id) == [gray, top])

        let clip = try command("Create Clipping Mask", in: "Layer", of: bar)
        #expect(try title(of: clip, in: controller) == "Create Clipping Mask")
        choose(clip, in: controller)
        #expect(session.activeLayer?.maskSourceID == gray)
        #expect(try title(of: clip, in: controller) == "Release Clipping Mask")
        choose(clip, in: controller)
        #expect(session.activeLayer?.maskSourceID == nil)

        let hide = try command("Hide Layer", in: "Layer", of: bar)
        choose(hide, in: controller)
        #expect(session.activeLayer?.isVisible == false)
        #expect(try title(of: hide, in: controller) == "Show Layer")
        choose(hide, in: controller)
        #expect(session.activeLayer?.isVisible == true)

        let merge = try command("Merge Down", in: "Layer", of: bar)
        #expect(try title(of: merge, in: controller) == session.mergeTitle)
        #expect(takes(merge, in: controller) == session.canMergeLayers)

        let blank = try command("New Blank Layer", in: "Layer", of: bar)
        choose(blank, in: controller)
        #expect(session.document?.layers.count == 3)
        #expect(session.activeLayer.map { $0.asset == nil && !$0.isGroup && $0.id != gray && $0.id != top } == true)
    }

    /// Folders, as the Mac's Layer menu makes and undoes them.
    @Test func theLayerMenuGroupsLayers() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        let gray = try #require(session.activeLayerID)
        let layers = session.document?.layers.map(\.id)

        let ungroup = try command("Ungroup Layers", in: "Layer", of: bar)
        let out = try command("Move Out of Folder", in: "Layer", of: bar)
        #expect(!takes(ungroup, in: controller) && !takes(out, in: controller))
        choose(try command("Group Selected Layers", in: "Layer", of: bar), in: controller)
        let folder = try #require(session.activeLayer)
        #expect(folder.isGroup && session.document?.layers.first { $0.id == gray }?.parentID == folder.id)

        session.selectLayers([gray], primary: gray)
        choose(out, in: controller)
        #expect(session.document?.layers.first { $0.id == gray }?.parentID == nil)
        session.selectLayers([folder.id], primary: folder.id)
        choose(ungroup, in: controller)
        #expect(session.document?.layers.map(\.id) == layers)
    }

    /// Delete is named as the Mac's is for what it will delete: the layer, the layers selected, or the mask.
    @Test func deleteIsNamedForWhatItDeletes() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        let delete = try command("Delete Layer", in: "Layer", of: bar)
        let gray = try #require(session.activeLayerID)
        #expect(try title(of: delete, in: controller) == "Delete Layer")

        session.addMask(revealing: true)
        try #require(session.isMaskSelected && session.activeLayer?.mask != nil)
        #expect(try title(of: delete, in: controller) == "Delete Layer Mask")
        choose(delete, in: controller)
        #expect(session.activeLayer?.mask == nil)

        session.selectLayerTarget(gray, mask: false)
        session.addBlankLayer()
        session.selectLayers(Set(session.document?.layers.map(\.id) ?? []), primary: session.activeLayerID)
        #expect(try title(of: delete, in: controller) == "Delete Layers")
        choose(delete, in: controller)
        #expect(session.document?.layers.isEmpty == true)
        #expect(!takes(delete, in: controller))
    }

    /// Flip Layer turns the layer over about its middle; Image › Flip Canvas turns the whole canvas over, about its
    /// middle, so a layer off to one side goes to the other.
    @Test func flipTurnsTheLayerOrTheCanvasOver() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform.origin = CGPoint(x: 20, y: 10)
        choose(try command("Flip Layer Horizontal", in: "Layer", of: bar), in: controller)
        #expect(session.activeLayer?.transform.flipX == true)
        choose(try command("Flip Layer Vertical", in: "Layer", of: bar), in: controller)
        #expect(session.activeLayer?.transform.flipY == true)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 20, y: 10))
        choose(try command("Flip Canvas Horizontal", in: "Image", of: bar), in: controller)
        #expect(session.activeLayer?.transform.flipX == false)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: -20, y: 10))
        choose(try command("Flip Canvas Vertical", in: "Image", of: bar), in: controller)
        #expect(session.activeLayer?.transform.flipY == false)
        #expect(session.activeLayer?.transform.origin == CGPoint(x: -20, y: -10))
    }

    /// Rename Layer… asks for the new name in the Layers panel's Rename alert, as the Mac's opens its name for typing.
    @Test func renameLayerAsksForTheName() async throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let controller = try window()
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.updatePropertiesIfNeeded()
        let session = try #require(controller.activeTab?.session)

        choose(try command("Rename Layer…", in: "Layer", of: bar), in: controller)
        for _ in 0..<100 where !(controller.presentedViewController is UIAlertController) { try await Task.sleep(for: .milliseconds(20)) }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Rename Layer")
        #expect(alert.textFields?.first?.text == "Gray")
        #expect(alert.actions.map(\.title) == ["Cancel", "Rename"])
        // The panel's alert, not the Mac's renaming in place, which would hold the layers.
        #expect(session.renamingLayerID == nil && session.canEditLayers)
        // Another can't come over it.
        #expect(!takes(try command("Rename Layer…", in: "Layer", of: bar), in: controller))
        alert.dismiss(animated: false)
    }

    // MARK: View

    /// The View menu is the Mac's after the zoom commands: its switches, with their shortcuts, and Clear Guides.
    @Test func theViewMenuIsTheMacs() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let view = try #require(bar.menu(titled: "View"))
        func elements(_ menu: MenuBarModel.Menu) -> [UIMenuElement] {
            menu.children.flatMap { item -> [UIMenuElement] in
                switch item {
                case .menu(let menu): menu.options.contains(.displayInline) ? elements(menu) : [UIMenu(title: menu.title, children: [])]
                case .element(let element): [element]
                }
            }
        }
        #expect(elements(view).map(\.title) == ["Fit Canvas", "Actual Pixels", "Zoom In", "Zoom Out", "Pixel Grid (800% and above)",
                                                "Snap", "Show Transform Controls", "Show", "Grid Settings…", "Rulers", "Snap", "Snap To",
                                                "Lock Guides", "Clear Guides", "Customize Toolbar…"])
        #expect(view.submenus.map(\.title) == ["Show", "Snap To"])
        #expect(view.submenus[0].commands.map(\.title) == ["Grid", "Guides"])
        #expect(view.submenus[1].commands.map(\.title) == ["Guides", "Grid", "Layers", "Document Bounds"])
        #expect(view.commands.map(shortcut) == ["⌘0", "⌘1", "⌘=", "⌘-", "", "", "", "⌘'", "⌘;", "⌘R", "⇧⌘;", "", "", "", "",
                                                "⌥⌘;", "", ""])
    }

    /// The View menu's switches turn the window's settings on and off, checked when they're on, as on the Mac.
    @Test func theViewSwitchesTurnSettingsOnAndOff() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let view = try #require(bar.menu(titled: "View"))
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let session = try #require(controller.activeTab?.session)
        let switches: [(UICommand, ReferenceWritableKeyPath<EditorSession, Bool>)] = [
            (view.commands[5], \.snappingEnabled), (view.submenus[0].commands[0], \.showsGrid),
            (view.submenus[0].commands[1], \.showsGuides), (view.commands[10], \.snapEnabled),
            (view.submenus[1].commands[0], \.snapToGuides), (view.submenus[1].commands[1], \.snapToGrid),
            (view.submenus[1].commands[2], \.snapToLayers), (view.submenus[1].commands[3], \.snapToDocumentBounds),
        ]
        // Without a project only the first Snap, which is the window's, as on the Mac.
        #expect(switches.map { takes($0.0, in: controller) } == [true] + Array(repeating: false, count: 7))
        session.createNewProject(width: 200, height: 100)
        for (command, setting) in switches {
            let was = session[keyPath: setting]
            let shown = try #require(command.copy() as? UICommand)
            controller.validate(shown)
            #expect(shown.state == (was ? .on : .off), "\(command.title)")
            choose(command, in: controller)
            #expect(session[keyPath: setting] == !was, "\(command.title)")
            controller.validate(shown)
            #expect(shown.state == (was ? .off : .on), "\(command.title)")
        }
    }

    /// Show Transform Controls is the Move tool's, as on the Mac, and its bar's Show Controls follows it.
    @Test func showTransformControlsIsTheMoveTools() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let command = try command("Show Transform Controls", in: "View", of: bar)
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        session.selectTool(.brush)
        #expect(!takes(command, in: controller))
        session.selectTool(.move)
        let options = ToolOptionsBar(frame: CGRect(x: 0, y: 0, width: 1000, height: ToolOptionsBar.height))
        options.session = session
        options.updatePropertiesIfNeeded()
        func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
            view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
        }
        let checkbox = try #require(views(UIButton.self, in: options).first { $0.configuration?.title == "Show Controls" })
        #expect(session.showsTransformControls && checkbox.isSelected)
        choose(command, in: controller)
        options.updatePropertiesIfNeeded()
        #expect(!session.showsTransformControls && !checkbox.isSelected)
    }

    /// Clear Guides takes the project's guides away as one undo step, and only when it has some.
    @Test func clearGuidesTakesTheGuidesAway() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let command = try command("Clear Guides", in: "View", of: bar)
        let controller = try window()
        let session = try #require(controller.activeTab?.session)
        #expect(!takes(command, in: controller))
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 50))
        choose(command, in: controller)
        #expect(session.document?.guides.isEmpty == true)
        #expect(session.history.undoName == "Clear Guides")
        #expect(!takes(command, in: controller))
    }

    /// What the iPad doesn't draw yet — the pixel grid and rulers — and Lock Guides, while guides can't be dragged, are
    /// listed as on the Mac, dimmed, and unchecked, since they do nothing.
    @Test func whatTheViewCantDoYetIsDimmed() throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let view = try #require(bar.menu(titled: "View"))
        let controller = try window()
        for command in view.commands where ["Pixel Grid (800% and above)", "Rulers", "Lock Guides"].contains(command.title) {
            #expect(!takes(command, in: controller), "\(command.title)")
            let shown = try #require(command.copy() as? UICommand)
            controller.validate(shown)
            #expect(shown.state == .off, "\(command.title)")
        }
        func elements(_ menu: MenuBarModel.Menu) -> [UIMenuElement] {
            menu.children.flatMap { item -> [UIMenuElement] in
                switch item {
                case .menu(let menu): elements(menu)
                case .element(let element): [element]
                }
            }
        }
        let settings = try #require(elements(view).first { $0.title == "Grid Settings…" } as? UIAction)
        #expect(settings.attributes.contains(.disabled))
    }
}
