import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Compositor

/// What the window shows over a tab, by the names the tests go by: the dialogs, the sheets an import puts up, the
/// alerts, and the system's pickers.
private let dialogs = ["Image Size", "Canvas Size", "Export JPEG", "Contract Selection", "Photoshop file", "RAW file", "Rename",
                       "Rename Layer", "Error", "Open Project", "Import Images", "Import from Photos", "Color"]
/// Each with its OK and with its Cancel, but for those with one way out in a test: a message's OK, and Photos' picker,
/// which can only be cancelled.
private let endings: [(String, Bool)] = dialogs.flatMap { dialog -> [(String, Bool)] in
    switch dialog {
    case "Error": [(dialog, true)]
    case "Import from Photos": [(dialog, false)]
    default: [(dialog, true), (dialog, false)]
    }
}
/// Those the window asks for at once, which come up before work set going just before them can finish.
private let askedAtOnce = ["Image Size", "Canvas Size", "Rename", "Rename Layer", "Open Project", "Import Images",
                           "Import from Photos", "Color"]

/// The window's dialogs and its tabs on iPad. Whatever the window shows over a tab but an effect's panel, a dialog, an
/// alert, a sheet or a picker, is over that tab's project, so it keeps the window on that tab until it has gone, as an
/// adjustment's editor does: what would bring another tab forward or close one is dimmed meanwhile, and a project
/// opened from elsewhere opens behind, coming forward once what was over the window is done.
@MainActor struct PadDialogTabsTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Waits up to a few seconds for `condition`, as the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A 200 × 100 project with a gray layer at the top, in `session`.
    private func fill(_ session: EditorSession) throws {
        session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
    }

    /// A window on the app's screen as the app makes one, the editor in a navigation controller whose bar is its toolbar,
    /// once it has appeared. Its tab in front holds a project with a gray layer and a file of its own, unless `empty`.
    private func shownWindow(empty: Bool = false) async throws -> (window: UIWindow, controller: EditorWindowController, tab: EditorTab) {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let controller = EditorWindowController()
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let tab = try #require(controller.activeTab)
        if !empty {
            try fill(tab.session)
            try await tab.createDocument(named: "PadDialogTabsTests \(UUID().uuidString)")
        }
        return (window, controller, tab)
    }

    /// A project with a gray layer saved in a folder of its own, as another app hands it over.
    private func savedProject(_ name: String = "Project") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PadDialogTabsTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let session = EditorSession()
        try fill(session)
        let url = folder.appending(path: name + ".comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// A 20 × 20 red PNG in a folder of its own, as Files hands one over.
    private func savedImage() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PadDialogTabsTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let context = try BrushRaster.context(width: 20, height: 20, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let url = folder.appending(path: "Red.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    /// Writes a project with another layer over the package at `url`, as another app would: through a file coordinator,
    /// which tells the document that has it open. Off the main thread, where the document is told.
    private func writeElsewhere(_ url: URL) async throws {
        let session = EditorSession()
        try fill(session)
        session.addBlankLayer()
        nonisolated(unsafe) let package = try ProjectStore.package(for: try #require(session.projectSnapshot()))
        try await Task.detached {
            var coordinationError: NSError?, writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try? FileManager.default.removeItem(at: url)
                    try package.write(to: url, options: [], originalContentsURL: nil)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
    }

    /// Takes away the folder `url` was saved in.
    private func remove(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: folder)
    }

    /// Closes every tab of the window as closing the window does, taking away the files the tabs made for themselves.
    private func cleanUp(_ controller: EditorWindowController) async {
        controller.presentedViewController?.dismiss(animated: false)
        for tab in controller.tabs {
            let url = tab.document?.fileURL
            await tab.close()
            if let url, url.deletingLastPathComponent().standardizedFileURL == CompositorDocument.projectsFolder.standardizedFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: What the window shows

    /// What the window shows over a tab while it's up: a dialog, a sheet, an alert or a picker, with what its OK
    /// answers for the editor, when the editor waits on one.
    private struct Shown {
        let controller: UIViewController
        var answer: Task<Bool, Never>?
        var alert: UIAlertController? { controller as? UIAlertController }
    }

    /// Brings `dialog` up over the tab in front, the way the app brings it up, and waits for it to show.
    private func bringUp(_ dialog: String, in controller: EditorWindowController) async throws -> Shown {
        try await showing(dialog, in: controller, answering: try ask(for: dialog, in: controller))
    }

    /// Asks for `dialog` over the tab in front, the way the app does, and returns what will hear its answer, when the
    /// editor waits on one.
    private func ask(for dialog: String, in controller: EditorWindowController) throws -> Task<Bool, Never>? {
        typealias Window = EditorWindowController
        let session = try #require(controller.activeTab?.session)
        // The menu bar's command that asks for it, if one does.
        var command: Selector?
        var answer: Task<Bool, Never>?
        switch dialog {
        case "Image Size": command = #selector(Window.imageSize(_:))
        case "Canvas Size": command = #selector(Window.canvasSize(_:))
        case "Export JPEG": command = #selector(Window.exportJPEG(_:))
        case "Contract Selection":
            session.selectAll()
            command = #selector(Window.contractSelection(_:))
        case "Photoshop file":
            // As an import of a Photoshop file that loses something on the way in asks.
            let conversions = [PSDConversion(layerName: "Title", message: "Type is rasterized.")]
            answer = Task { await session.confirmPSDConversions(conversions, title: "Import “Poster.psd”", confirmTitle: "Import") }
        case "RAW file":
            // As an import of a RAW file asks; this one can't be developed, so the preview stays empty.
            let url = FileManager.default.temporaryDirectory.appending(path: "PadDialogTabsTests \(UUID().uuidString).dng")
            try Data("Not a RAW file".utf8).write(to: url)
            answer = Task {
                defer { try? FileManager.default.removeItem(at: url) }
                return await session.developRaw(url) != nil
            }
        case "Rename": command = #selector(Window.renameProject(_:))
        case "Rename Layer": command = #selector(Window.renameLayer(_:))
        case "Error": session.brushError = "The brush ran out of room."
        case "Open Project": command = #selector(Window.openProject(_:))
        case "Import Images": command = #selector(Window.importImages(_:))
        case "Import from Photos": command = #selector(Window.importPhotos(_:))
        case "Color":
            let swatch = try #require(views(UIControl.self, in: controller.view).first { $0.accessibilityLabel == "Foreground color" })
            swatch.sendActions(for: .primaryActionTriggered)
        default: Issue.record("No dialog called \(dialog)")
        }
        if let command {
            try #require(controller.canPerformAction(command, withSender: nil), "\(dialog)")
            controller.perform(command, with: nil)
        }
        return answer
    }

    /// `dialog` over the window, once it shows.
    private func showing(_ dialog: String, in controller: EditorWindowController, answering answer: Task<Bool, Never>?) async throws -> Shown {
        try await eventually {
            guard let shown = controller.presentedViewController else { return false }
            return !shown.isBeingPresented && !(shown is EffectEditorController)
        }
        let shown = try #require(controller.presentedViewController, "\(dialog)")
        try #require(!shown.isBeingPresented, "\(dialog)")
        switch dialog {
        case "Image Size": try #require(shown is ImageSizeController)
        case "Canvas Size": try #require(shown is CanvasSizeController)
        case "Export JPEG": try #require(shown is JPEGExportController)
        case "Photoshop file": try #require((shown as? UINavigationController)?.viewControllers.first is PSDConversionController)
        case "RAW file": try #require((shown as? UINavigationController)?.viewControllers.first is RawDevelopController)
        case "Contract Selection", "Rename", "Rename Layer", "Error":
            let titles = ["Contract Selection": "Contract Selection", "Rename": "Rename", "Rename Layer": "Rename Layer",
                          "Error": "Couldn’t paint"]
            try #require((shown as? UIAlertController)?.title == titles[dialog], "\(String(describing: (shown as? UIAlertController)?.title))")
        case "Open Project", "Import Images": try #require(shown is UIDocumentPickerViewController)
        case "Import from Photos": try #require(shown is PHPickerViewController)
        case "Color": try #require(shown is UIColorPickerViewController)
        default: break
        }
        shown.view.layoutIfNeeded()
        return Shown(controller: shown, answer: answer)
    }

    /// The button titled `title` in `controller`'s view.
    private func button(_ title: String, in controller: UIViewController) throws -> UIButton {
        try #require(views(UIButton.self, in: controller.view).first { $0.configuration?.title == title }, "\(title)")
    }

    /// Presses the key `input` in `alert`, as a keyboard does: Escape for its Cancel.
    private func press(_ input: String, in alert: UIAlertController) throws {
        let command = try #require(alert.keyCommands?.first { $0.input == input }, "\(input)")
        let action = try #require(command.action)
        alert.perform(action, with: command)
    }

    /// Types `text` in `alert`'s field and presses Return there, which is its OK.
    private func enter(_ text: String, in alert: UIAlertController) throws {
        let field = try #require(alert.textFields?.first)
        field.text = text
        field.sendActions(for: .editingDidEndOnExit)
    }

    /// What the pickers pick: a project to open, and an image to bring in.
    private struct Picks {
        let project: URL
        let image: URL
    }

    /// Ends `shown` with its OK, or its Cancel, as a finger or the keyboard does. Export JPEG's OK offers the JPEG in a
    /// share sheet, which is put away too, once it's checked that the window is still on `front` under it.
    private func end(_ dialog: String, _ shown: Shown, ok: Bool, picks: Picks, front: EditorTab,
                     in controller: EditorWindowController) async throws {
        switch dialog {
        case "Image Size", "Canvas Size":
            let size = try #require(shown.controller as? SizeDialogController)
            if ok {
                if let image = size as? ImageSizeController {
                    image.chooseUnit(.percent)
                    image.setDimension(50, widthAxis: true)
                } else {
                    try #require(size as? CanvasSizeController).setDimension(300, widthAxis: true)
                }
                size.confirmButton.sendActions(for: .primaryActionTriggered)
                await controller.resizing?.value
            } else {
                try button("Cancel", in: size).sendActions(for: .primaryActionTriggered)
            }
        case "Export JPEG":
            let export = try #require(shown.controller as? JPEGExportController)
            guard ok else {
                try button("Cancel", in: export).sendActions(for: .primaryActionTriggered)
                break
            }
            await export.encoding?.value
            try button("Export…", in: export).sendActions(for: .primaryActionTriggered)
            try await eventually { (controller.presentedViewController as? UIActivityViewController)?.isBeingPresented == false }
            let share = try #require(controller.presentedViewController as? UIActivityViewController)
            #expect(controller.activeTab === front, "The share sheet is over the tab it exports")
            share.dismiss(animated: true)
        case "Contract Selection", "Rename", "Rename Layer":
            let alert = try #require(shown.alert)
            if ok {
                try enter(dialog == "Contract Selection" ? "7" : "Renamed", in: alert)
            } else {
                try press(UIKeyCommand.inputEscape, in: alert)
            }
        case "Error":
            // Its OK only puts it away.
            try #require(shown.alert).dismiss(animated: true)
        case "Photoshop file", "RAW file":
            let sheet = try #require((shown.controller as? UINavigationController)?.viewControllers.first)
            sheet.updatePropertiesIfNeeded()
            if ok {
                let item = try #require(sheet.navigationItem.rightBarButtonItem)
                _ = UIApplication.shared.sendAction(try #require(item.action), to: item.target, from: item, for: nil)
            } else {
                try #require(sheet.navigationItem.leftBarButtonItem?.primaryAction).performWithSender(nil, target: nil)
            }
        case "Open Project", "Import Images":
            // The picker puts itself away, then says what was picked once it has gone, as UIKit's does.
            let picker = try #require(shown.controller as? UIDocumentPickerViewController)
            let url = dialog == "Open Project" ? picks.project : picks.image
            picker.dismiss(animated: true) { if ok { controller.documentPicker(picker, didPickDocumentsAt: [url]) } }
        case "Import from Photos":
            let picker = try #require(shown.controller as? PHPickerViewController)
            controller.picker(picker, didFinishPicking: [])
        case "Color":
            let picker = try #require(shown.controller as? UIColorPickerViewController)
            if ok {
                let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
                picker.selectedColor = red
                picker.delegate?.colorPickerViewController?(picker, didSelect: red, continuously: false)
            }
            // A tap off the popover puts it away.
            picker.dismiss(animated: true)
        default: Issue.record("No dialog called \(dialog)")
        }
    }

    /// Expects what `dialog`'s OK does to have been done to `tab`'s project, not to `other`'s.
    private func expectDone(_ dialog: String, _ shown: Shown, on tab: EditorTab, not other: EditorTab, picks: Picks,
                            in controller: EditorWindowController, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let session = tab.session
        switch dialog {
        case "Image Size":
            #expect(session.document?.width == 100 && other.session.document?.width == 200, sourceLocation: sourceLocation)
        case "Canvas Size":
            #expect(session.document?.width == 300 && other.session.document?.width == 200, sourceLocation: sourceLocation)
        case "Export JPEG":
            let file = FileManager.default.temporaryDirectory.appending(path: tab.title + ".jpg")
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), sourceLocation: sourceLocation)
            try? FileManager.default.removeItem(at: file)
        case "Contract Selection":
            #expect(session.selectionContractAmount == 7 && other.session.selectionContractAmount != 7, sourceLocation: sourceLocation)
        case "Photoshop file", "RAW file":
            #expect(await shown.answer?.value == true, sourceLocation: sourceLocation)
        case "Rename":
            try await eventually { tab.title == "Renamed" }
            #expect(tab.title == "Renamed" && other.title != "Renamed", sourceLocation: sourceLocation)
        case "Rename Layer":
            #expect(session.activeLayer?.name == "Renamed", sourceLocation: sourceLocation)
            #expect(other.session.document?.layers.contains { $0.name == "Renamed" } == false, sourceLocation: sourceLocation)
        case "Open Project":
            let picked = controller.tabs.first { $0.url?.standardizedFileURL == picks.project.standardizedFileURL }
            #expect(picked != nil && picked !== tab && picked !== other, sourceLocation: sourceLocation)
        case "Import Images":
            let count = other.session.document?.layers.count ?? 0
            try await eventually { session.document?.layers.count == count + 1 }
            #expect(session.document?.layers.count == count + 1 && session.activeLayer?.name == "Red", sourceLocation: sourceLocation)
        case "Color":
            #expect(session.foregroundColor == PaletteColor(red: 1, green: 0, blue: 0), sourceLocation: sourceLocation)
            #expect(other.session.foregroundColor != PaletteColor(red: 1, green: 0, blue: 0), sourceLocation: sourceLocation)
        default: break
        }
    }

    /// What `dialog`'s Cancel leaves of the editor's question, when it waits on one: no answer.
    private func expectCancelled(_ dialog: String, _ shown: Shown, sourceLocation: SourceLocation = #_sourceLocation) async {
        if let answer = shown.answer { #expect(await answer.value == false, sourceLocation: sourceLocation) }
    }

    // MARK: The tabs

    /// The menu bar's commands that would bring another tab forward or close one: New Canvas…, Open Project…, a project
    /// in Open Recent, the imports, Duplicate, Rename… and Close Tab.
    private func tabCommands() throws -> [UICommand] {
        let file = try #require(MenuBarModel.built(by: AppDelegate()).menu(titled: "File"))
        let titles = ["New Canvas…", "Open Project…", "Import Images…", "Import from Photos…", "Duplicate", "Rename…", "Close Tab"]
        let commands = file.commands.filter { titles.contains($0.title) }
        try #require(commands.map(\.title) == titles)
        let recent = AppDelegate.recentItems(for: [CompositorDocument.projectsFolder.appending(path: "Harbor.comp")])
        let project = try #require((recent.first as? UIMenu)?.children.first as? UICommand)
        return commands + [project]
    }

    /// The tab strip as the window shows it now: its tabs, in order, and their close buttons.
    private func tabStrip(of controller: EditorWindowController) throws -> (strip: TabStripView, tabs: [UIControl], closes: [UIButton]) {
        controller.updatePropertiesIfNeeded()
        let strip = try #require(controller.navigationItem.titleView as? TabStripView)
        let controls = views(UIControl.self, in: strip)
        return (strip, controls.filter { !($0 is UIButton) }, controls.compactMap { $0 as? UIButton })
    }

    /// The toolbar's New Canvas button.
    private func newTabItem(of controller: EditorWindowController) throws -> UIBarButtonItem {
        controller.updatePropertiesIfNeeded()
        let items = controller.navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
        return try #require(items.first { $0.accessibilityLabel == "New canvas" })
    }

    /// Expects what would switch or close tabs to be there for a finger, the keyboard, the menu bar and VoiceOver when
    /// `free`, and dimmed otherwise: the commands, the toolbar's New Canvas, the tabs behind `front` and every close
    /// button, and the tabs' context menus.
    private func expectTabs(free: Bool, in controller: EditorWindowController, front: EditorTab,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        for command in try tabCommands() {
            #expect(controller.canPerformAction(command.action, withSender: command) == free, "\(command.title)",
                    sourceLocation: sourceLocation)
        }
        #expect(try newTabItem(of: controller).isEnabled == free, "New canvas", sourceLocation: sourceLocation)
        let (strip, pills, closes) = try tabStrip(of: controller)
        #expect(pills.count == controller.tabs.count && closes.count == controller.tabs.count, sourceLocation: sourceLocation)
        for (tab, pill) in zip(controller.tabs, pills) {
            let dimmed = !free && tab !== front
            #expect(pill.isEnabled == !dimmed, "\(pill.accessibilityLabel ?? "")", sourceLocation: sourceLocation)
            let traits = pill.accessibilityTraits
            #expect(traits.contains(.notEnabled) == dimmed && traits.contains(.selected) == (tab === front),
                    "\(pill.accessibilityLabel ?? "")", sourceLocation: sourceLocation)
            let actions = (strip.menu(tab.id)?.children ?? []).flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { $0 as? UIAction }
            #expect(!actions.isEmpty && actions.allSatisfy { $0.attributes.contains(.disabled) == !free },
                    "\(actions.map(\.title))", sourceLocation: sourceLocation)
        }
        for close in closes { #expect(close.isEnabled == free, "\(close.accessibilityLabel ?? "")", sourceLocation: sourceLocation) }
    }

    // MARK: Projects opened meanwhile

    /// A project opened from elsewhere while something is over the window, from Files or Open in Compositor, opens at
    /// once in a tab behind, dimmed as the others are, what's over the window staying on its own tab; once its OK has
    /// done what it does to that tab's project, or its Cancel let it go, the project comes forward, with nothing over
    /// it. A project picked in Open Project meanwhile was asked for later, so it's the one that comes forward.
    @Test(arguments: endings)
    func aProjectOpenedFromElsewhereOpensBehind(_ dialog: String, ok: Bool) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let shown = try await bringUp(dialog, in: controller)
        try expectTabs(free: false, in: controller, front: tab)
        let url = try savedProject()
        defer { remove(url) }

        // As the scene hands it over.
        controller.open([url])
        #expect(controller.tabs.count == 2)
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && opened.url == url)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        try expectTabs(free: false, in: controller, front: tab)
        try await eventually { opened.document != nil }
        #expect(opened.document != nil)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)

        try await end(dialog, shown, ok: ok, picks: picks, front: tab, in: controller)
        let picked = dialog == "Open Project" && ok
        func front() -> EditorTab? {
            picked ? controller.tabs.first { $0.url?.standardizedFileURL == picks.project.standardizedFileURL } : opened
        }
        try await eventually { controller.activeTab === front() && controller.presentedViewController == nil }
        #expect(controller.activeTab === front() && controller.activeTab != nil)
        #expect(controller.presentedViewController == nil)
        if ok { try await expectDone(dialog, shown, on: tab, not: opened, picks: picks, in: controller) }
        else { await expectCancelled(dialog, shown) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.activeTab === front() && controller.presentedViewController == nil)
        try expectTabs(free: true, in: controller, front: try #require(front()))
        await cleanUp(controller)
    }

    /// Another window opening a project open in this one, as it does for a project from Files, waits as well: the
    /// project's tab here comes forward once what's over this window is done, and the other window opens nothing.
    @Test(arguments: dialogs)
    func anotherWindowsOpenWaits(_ dialog: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let behind = try #require(controller.activeTab)
        try await eventually { behind.document != nil }
        controller.select(tab.id)
        controller.updatePropertiesIfNeeded()
        try #require(controller.activeTab === tab)
        let shown = try await bringUp(dialog, in: controller)

        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let otherWindow = UIWindow(windowScene: scene)
        otherWindow.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let other = EditorWindowController()
        otherWindow.rootViewController = UINavigationController(rootViewController: other)
        otherWindow.isHidden = false
        defer { otherWindow.isHidden = true }
        other.view.layoutIfNeeded()
        other.open([url])
        #expect(other.tabs.count == 1 && other.activeTab?.isEmpty == true)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)

        try await end(dialog, shown, ok: dialog == "Error", picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === behind && controller.presentedViewController == nil }
        #expect(controller.activeTab === behind && controller.presentedViewController == nil)
        await cleanUp(controller)
        await cleanUp(other)
    }

    /// What the window shows holds it from the moment it's asked for, before UIKit puts it up, as a popover or a picker
    /// it readies first: a project opened from elsewhere just after opens behind as well.
    @Test(arguments: ["Open Project", "Import from Photos", "Color"])
    func aProjectOpenedAsSomethingIsAskedForOpensBehind(_ dialog: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let url = try savedProject()
        defer { remove(url) }
        let answer = try ask(for: dialog, in: controller)
        // Asked for, and not up yet.
        try #require(controller.presentedViewController == nil)
        try expectTabs(free: false, in: controller, front: tab)

        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && controller.activeTab === tab)
        let shown = try await showing(dialog, in: controller, answering: answer)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        try await end(dialog, shown, ok: false, picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === opened && controller.presentedViewController == nil }
        #expect(controller.activeTab === opened && controller.presentedViewController == nil)
        await cleanUp(controller)
    }

    /// The Layers panel's button for `title`, as the panel shows it now.
    private func layersButton(_ title: String, in controller: EditorWindowController) throws -> UIButton {
        for panel in views(LayersPanelView.self, in: controller.view) { panel.updatePropertiesIfNeeded() }
        return try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == title }, "\(title)")
    }

    /// Asked for beside an effect's panel, which gives way to it, what the window shows holds it from that moment as
    /// well, while the panel goes: a project opened from elsewhere just after opens behind, and what's shown comes up
    /// over the tab it was asked for, its OK done to that tab's project.
    @Test(arguments: ["Image Size", "Rename", "Color"])
    func somethingAskedForBesideAnEffectsPanelHoldsTheWindow(_ dialog: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let effects = try layersButton("Layer effects", in: controller)
        let stroke = try #require(effects.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == LayerEffectKind.stroke.rawValue + "…" })
        stroke.performWithSender(nil, target: nil)
        try await eventually { (controller.presentedViewController as? EffectEditorController)?.isBeingPresented == false }
        try #require(controller.presentedViewController is EffectEditorController)
        let url = try savedProject()
        defer { remove(url) }

        let answer = try ask(for: dialog, in: controller)
        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && controller.activeTab === tab)
        let shown = try await showing(dialog, in: controller, answering: answer)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        try await end(dialog, shown, ok: true, picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === opened && controller.presentedViewController == nil }
        #expect(controller.activeTab === opened && controller.presentedViewController == nil)
        try await expectDone(dialog, shown, on: tab, not: opened, picks: picks, in: controller)
        await cleanUp(controller)
    }

    /// A menu over the window, as the Layers panel's buttons show, holds it as what else it shows does, though UIKit
    /// doesn't dim the window behind it: a project opened from elsewhere meanwhile opens behind, and once the menu is
    /// put away with nothing chosen, the project comes forward and nothing is left dimmed.
    @Test(arguments: ["Layer effects", "New adjustment layer"])
    func aMenuHoldsTheWindowUntilItsPutAway(_ title: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        let button = try layersButton(title, in: controller)
        // As a tap does.
        button.performPrimaryAction()
        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let menu = try #require(controller.presentedViewController)
        try expectTabs(free: false, in: controller, front: tab)

        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && controller.activeTab === tab && controller.presentedViewController === menu)
        try expectTabs(free: false, in: controller, front: tab)
        try await eventually { opened.document != nil }
        // A tap off the menu puts it away.
        try #require(button.contextMenuInteraction).dismissMenu()
        try await eventually { controller.activeTab === opened && controller.presentedViewController == nil }
        #expect(controller.activeTab === opened && controller.presentedViewController == nil)
        try expectTabs(free: true, in: controller, front: opened)
        await cleanUp(controller)
    }

    /// The tabs stay as they are as the window comes to be held and is let go, dimmed and brought back in place, so a
    /// menu a tab shows of its own, which holds the window as any menu does, stays with the tab it came from: a menu
    /// stays up however often the window looks again meanwhile, and once it's put away, nothing is left dimmed.
    @Test func theTabsStayAsAMenuHoldsTheWindow() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let behind = try #require(controller.activeTab)
        try await eventually { behind.document != nil }
        controller.select(tab.id)
        let pills = try tabStrip(of: controller).tabs
        try #require(pills.count == 2)
        let button = try layersButton("Layer effects", in: controller)
        button.performPrimaryAction()
        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let menu = try #require(controller.presentedViewController)
        try expectTabs(free: false, in: controller, front: tab)
        #expect(try tabStrip(of: controller).tabs.elementsEqual(pills, by: ===))

        for _ in 0..<3 {
            controller.setNeedsUpdateProperties()
            controller.updatePropertiesIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(controller.presentedViewController === menu && controller.activeTab === tab)
        try #require(button.contextMenuInteraction).dismissMenu()
        try await eventually { controller.presentedViewController == nil && (try? newTabItem(of: controller).isEnabled) == true }
        try expectTabs(free: true, in: controller, front: tab)
        #expect(try tabStrip(of: controller).tabs.elementsEqual(pills, by: ===))
        await cleanUp(controller)
    }

    /// An empty tab in front doesn't take a project opened from elsewhere while something is over it, as it would
    /// otherwise: the project opens behind, so the images Import Images picks meanwhile come into the empty tab, as they
    /// were picked for it, and the project comes forward once the picker is done.
    @Test func anEmptyTabUnderAPickerIsLeftForWhatsPicked() async throws {
        let (window, controller, tab) = try await shownWindow(empty: true)
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let shown = try await bringUp("Import Images", in: controller)
        let url = try savedProject()
        defer { remove(url) }

        controller.open([url])
        #expect(controller.tabs.count == 2 && tab.isEmpty)
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && opened.url == url && controller.activeTab === tab)
        try await end("Import Images", shown, ok: true, picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === opened && controller.presentedViewController == nil && tab.document != nil }
        #expect(controller.activeTab === opened && controller.presentedViewController == nil)
        #expect(tab.session.document?.layers.map(\.name) == ["Red"] && tab.document != nil)
        await cleanUp(controller)
    }

    /// An export holds the window from the moment it's chosen, while it makes its image: Export JPEG's, which its
    /// dialog previews, and Export PNG's, which its share sheet offers. A project opened from elsewhere meanwhile opens
    /// behind, and the dialog or the share sheet comes up over the tab it exports.
    @Test(arguments: ["Export JPEG", "Export PNG"])
    func anExportHoldsTheWindowWhileItsImageIsMade(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let action = export == "Export JPEG" ? #selector(EditorWindowController.exportJPEG(_:)) : #selector(EditorWindowController.exportPNG(_:))
        try #require(controller.canPerformAction(action, withSender: nil))
        controller.perform(action, with: nil)
        try #require(controller.presentedViewController == nil)
        let url = try savedProject()
        defer { remove(url) }

        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && controller.activeTab === tab)
        try expectTabs(free: false, in: controller, front: tab)
        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let shown = try #require(controller.presentedViewController)
        #expect(export == "Export JPEG" ? shown is JPEGExportController : shown is UIActivityViewController)
        #expect(controller.activeTab === tab)

        if let dialog = shown as? JPEGExportController {
            try button("Cancel", in: dialog).sendActions(for: .primaryActionTriggered)
        } else {
            // A tap off the share sheet puts it away.
            shown.dismiss(animated: true)
        }
        try await eventually { controller.activeTab === opened && controller.presentedViewController == nil }
        #expect(controller.activeTab === opened && controller.presentedViewController == nil)
        #expect(!tab.session.isProjectBusy)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: tab.title + ".png"))
        await cleanUp(controller)
    }

    /// The menu bar's commands that show something over the window: Export PNG… and Export JPEG…, Canvas Size… and
    /// Image Size…, Rename Layer…, and those that open an adjustment's editor, Levels…, Curves…, Hue/Saturation…, a
    /// filter and a new adjustment layer.
    private func showingCommands() throws -> [UICommand] {
        let bar = MenuBarModel.built(by: AppDelegate())
        let file = try #require(bar.menu(titled: "File")).commands, image = try #require(bar.menu(titled: "Image")).commands
        let layer = try #require(bar.menu(titled: "Layer")), filter = try #require(bar.menu(titled: "Filter")).commands
        let new = try #require(layer.submenus.first { $0.title == "New Adjustment Layer" }).commands
        let commands = [file.first { $0.title == "Export PNG…" }, file.first { $0.title == "Export JPEG…" },
                        image.first { $0.title == "Canvas Size…" }, image.first { $0.title == "Image Size…" },
                        layer.commands.first { $0.title == "Rename Layer…" }, image.first { $0.title == "Levels…" },
                        image.first { $0.title == "Curves…" }, image.first { $0.title == "Hue/Saturation…" },
                        filter.first { $0.title == "Gaussian Blur…" }, new.first { $0.title == "Levels…" }].compactMap { $0 }
        try #require(commands.count == 10)
        return commands
    }

    /// Nothing else comes up over the window while an export makes its image, which its dialog or share sheet couldn't
    /// come up over: the commands that show something are dimmed, another export among them, and an error the editor
    /// runs into meanwhile waits. The dialog or the share sheet comes up; once it has gone, the error does, and the
    /// commands are back once that has gone too.
    @Test(arguments: ["Export JPEG", "Export PNG"])
    func nothingElseComesUpWhileAnExportMakesItsImage(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let commands = try showingCommands()
        func expectCommands(free: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            for command in commands {
                #expect(controller.canPerformAction(command.action, withSender: command) == free, "\(command.title)",
                        sourceLocation: sourceLocation)
            }
        }
        expectCommands(free: true)
        let action = export == "Export JPEG" ? #selector(EditorWindowController.exportJPEG(_:)) : #selector(EditorWindowController.exportPNG(_:))
        controller.perform(action, with: nil)
        try #require(controller.presentedViewController == nil)
        expectCommands(free: false)
        tab.session.brushError = "The brush ran out of room."

        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let shown = try #require(controller.presentedViewController)
        #expect(export == "Export JPEG" ? shown is JPEGExportController : shown is UIActivityViewController)
        expectCommands(free: false)
        if let dialog = shown as? JPEGExportController {
            try button("Cancel", in: dialog).sendActions(for: .primaryActionTriggered)
        } else {
            // A tap off the share sheet puts it away.
            shown.dismiss(animated: true)
        }
        try await eventually { (controller.presentedViewController as? UIAlertController)?.isBeingPresented == false }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Couldn’t paint" && controller.activeTab === tab)
        alert.dismiss(animated: true)
        try await eventually { controller.presentedViewController == nil }
        expectCommands(free: true)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: tab.title + ".png"))
        await cleanUp(controller)
    }

    /// Several projects opened from elsewhere meanwhile all open behind; the last asked for comes forward once what's
    /// over the window is done.
    @Test func severalOpenBehindAndTheLastComesForward() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let shown = try await bringUp("Canvas Size", in: controller)
        let urls = try ["First", "Second", "Third"].map(savedProject)
        defer { urls.forEach(remove) }

        controller.open([urls[0]])
        controller.open([urls[1], urls[2]])
        #expect(controller.tabs.map(\.url) == [tab.url] + urls)
        let opened = Array(controller.tabs.dropFirst())
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        try await eventually { controller.tabs.allSatisfy { $0.document != nil } }

        try await end("Canvas Size", shown, ok: false, picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === opened.last }
        #expect(controller.activeTab === opened.last)
        await cleanUp(controller)
    }

    /// Work that finishes while something is over the window, as a Duplicate's copy, opens behind as well, and comes
    /// forward once what's over the window is done.
    @Test(arguments: askedAtOnce)
    func aDuplicateFinishedMeanwhileOpensBehind(_ dialog: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let duplicate = #selector(EditorWindowController.duplicateProject(_:))
        try #require(controller.canPerformAction(duplicate, withSender: nil))
        controller.perform(duplicate, with: nil)
        let shown = try await bringUp(dialog, in: controller)

        try await eventually { controller.tabs.count == 2 && controller.tabs.last?.document != nil }
        let copy = try #require(controller.tabs.last)
        #expect(copy !== tab && copy.document != nil)
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)

        try await end(dialog, shown, ok: false, picks: picks, front: tab, in: controller)
        try await eventually { controller.activeTab === copy && controller.presentedViewController == nil }
        #expect(controller.activeTab === copy && controller.presentedViewController == nil)
        await cleanUp(controller)
    }

    // MARK: Closing

    /// A tab whose save failed as it closed waits for what's over another tab meanwhile to be done: then it comes
    /// forward, saying why, as it would have at once.
    @Test(arguments: askedAtOnce)
    func aClosingTabsFailedSaveWaits(_ dialog: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let closing = try #require(controller.activeTab)
        try await eventually { closing.document != nil }
        closing.session.addBlankLayer()
        try await eventually { closing.document?.hasUnsavedChanges == true }
        // Every save into its folder fails, as with a full disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))

        controller.close(closing.id)
        try tabStrip(of: controller).strip.onSelect(tab.id)
        controller.updatePropertiesIfNeeded()
        try #require(controller.activeTab === tab)
        let shown = try await bringUp(dialog, in: controller)
        // Its save fails meanwhile.
        try await eventually { closing.document?.documentState.contains(.savingError) == true || controller.activeTab !== tab }
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        #expect(controller.tabs.contains { $0 === closing } && shown.controller.presentedViewController == nil)

        try await end(dialog, shown, ok: false, picks: picks, front: tab, in: controller)
        try await eventually { saveQuestion(in: controller)?.isBeingPresented == false }
        let alert = try #require(saveQuestion(in: controller))
        #expect(alert.actions.map(\.title) == ["Don’t Save", "Cancel"])
        #expect(controller.activeTab === closing)
        alert.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))
        controller.closeWithoutSaving(closing.id)
        await cleanUp(controller)
    }

    /// The question a closing tab asks once its save has failed, while the window shows it.
    private func saveQuestion(in controller: EditorWindowController) -> UIAlertController? {
        (controller.presentedViewController as? UIAlertController).flatMap { $0.title == "Couldn’t save the project" ? $0 : nil }
    }

    /// Tabs whose saves failed as they closed, while something was over another tab, ask one at a time once it's done,
    /// each over its own tab, the next once the question before it is answered: Don't Save in one lets go of that tab's
    /// project, and no other.
    @Test func closingTabsAskOneAtATime() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let urls = try ["First", "Second"].map(savedProject)
        defer { urls.forEach(remove) }
        var closing: [EditorTab] = []
        for url in urls {
            controller.open([url])
            let opened = try #require(controller.activeTab)
            try await eventually { opened.document != nil }
            opened.session.addBlankLayer()
            try await eventually { opened.document?.hasUnsavedChanges == true }
            closing.append(opened)
        }
        // Every save into their folders fails, as with a full disk.
        for url in urls {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))
        }

        closing.forEach { controller.close($0.id) }
        try tabStrip(of: controller).strip.onSelect(tab.id)
        controller.updatePropertiesIfNeeded()
        try #require(controller.activeTab === tab)
        let shown = try await bringUp("Canvas Size", in: controller)
        try await eventually { closing.allSatisfy { $0.document?.documentState.contains(.savingError) == true } }
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.activeTab === tab && controller.presentedViewController === shown.controller)
        #expect(shown.controller.presentedViewController == nil)

        try await end("Canvas Size", shown, ok: false, picks: picks, front: tab, in: controller)
        var asked: [EditorTab] = []
        for _ in closing {
            try await eventually { saveQuestion(in: controller).map { !$0.isBeingPresented && !$0.isBeingDismissed } == true }
            let question = try #require(saveQuestion(in: controller))
            let front = try #require(controller.activeTab)
            #expect(closing.contains { $0 === front } && !asked.contains { $0 === front })
            asked.append(front)
            try await Task.sleep(for: .milliseconds(300))
            #expect(controller.activeTab === front && controller.presentedViewController === question)
            #expect(question.presentedViewController == nil)
            if asked.count == 1 {
                // Don't Save, as a tap does: once the question has gone, the tab closes.
                question.dismiss(animated: true) { controller.closeWithoutSaving(front.id) }
                try await eventually { !controller.tabs.contains { $0 === front } }
                #expect(!controller.tabs.contains { $0 === front })
            } else {
                // Cancel keeps the tab.
                try press(UIKeyCommand.inputEscape, in: question)
                try await eventually { controller.presentedViewController == nil }
            }
        }
        #expect(asked.count == 2)
        let kept = try #require(asked.last)
        #expect(controller.tabs.contains { $0 === kept } && kept.document?.hasUnsavedChanges == true)
        for url in urls {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))
        }
        controller.closeWithoutSaving(kept.id)
        await cleanUp(controller)
    }

    /// Something asked for over a tab as it saves to close keeps it in front, as anything over a tab does: the tab
    /// closes once that's done, saving what its OK did, and the tab behind comes forward. Image Size, which holds the
    /// project, keeps the save waiting too.
    @Test(arguments: [("Image Size", true), ("Rename Layer", true), ("Rename", false)])
    func aTabClosingUnderADialogWaitsForIt(_ dialog: String, ok: Bool) async throws {
        let (window, controller, behind) = try await shownWindow()
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let closing = try #require(controller.activeTab)
        try await eventually { closing.document != nil }
        try #require(closing.document != nil)

        // Asked for at once, as it begins to save.
        controller.close(closing.id)
        let shown = try await bringUp(dialog, in: controller)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.tabs.contains { $0 === closing } && controller.activeTab === closing)
        #expect(controller.presentedViewController === shown.controller)

        try await end(dialog, shown, ok: ok, picks: picks, front: closing, in: controller)
        try await eventually {
            !controller.tabs.contains { $0 === closing } && controller.activeTab === behind && controller.presentedViewController == nil
        }
        #expect(!controller.tabs.contains { $0 === closing } && controller.activeTab === behind)
        #expect(controller.presentedViewController == nil)
        if ok {
            try await eventually { closing.isClosed && closing.document == nil }
            let saved = try ProjectStore.readPackage(url).manifest
            if dialog == "Image Size" { #expect(saved.width == 100) } else { #expect(saved.layers.contains { $0.name == "Renamed" }) }
        }
        await cleanUp(controller)
    }

    /// A closing tab's question about a change made elsewhere holds the window on it, as anything else over a tab does,
    /// though the tab is closing: a project opened from elsewhere while it asks opens behind, and comes forward once the
    /// question is answered and the tab has closed.
    @Test func aClosingTabsQuestionHoldsTheWindow() async throws {
        let (window, controller, _) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let closing = try #require(controller.activeTab)
        try await eventually { closing.document != nil }
        let document = try #require(closing.document)
        // Unsaved work, and a transform under way, which a change made elsewhere waits for.
        let first = try #require(closing.session.document?.layers.first?.id)
        closing.session.renameLayer(first, to: "Unsaved here")
        closing.session.beginTransform()
        try await writeElsewhere(url)
        try await eventually { document.changeWaits }
        try #require(document.changeWaits)

        // Closing settles the transform, and the change asks.
        controller.close(closing.id)
        try await eventually { (controller.presentedViewController as? UIAlertController)?.isBeingPresented == false }
        let question = try #require(controller.presentedViewController as? UIAlertController)
        #expect(question.title == "“Project.comp” was changed on disk." && controller.activeTab === closing)
        let other = try savedProject("Other")
        defer { remove(other) }
        controller.open([other])
        let opened = try #require(controller.tabs.last)
        #expect(opened.url == other && controller.activeTab === closing && controller.presentedViewController === question)

        // Keep Mine, and the tab closes, saving what it has.
        try press(UIKeyCommand.inputEscape, in: question)
        try await eventually { !controller.tabs.contains { $0 === closing } && controller.activeTab === opened }
        #expect(!controller.tabs.contains { $0 === closing } && controller.activeTab === opened)
        #expect(controller.presentedViewController == nil)
        await cleanUp(controller)
    }

    // MARK: The window's own pickers

    /// Open Project… picks a project for the window to open, which an empty tab in front takes, as before; and Import
    /// Images… images for the project in front. Whether the picker has gone or is still going as it says what was
    /// picked, it's done at once or as soon as the picker has gone.
    @Test(arguments: ["Open Project", "Import Images"], [true, false])
    func thePickersStillOpenWhatsPicked(_ dialog: String, pickedAsItGoes: Bool) async throws {
        let (window, controller, tab) = try await shownWindow(empty: true)
        defer { window.isHidden = true }
        let picks = Picks(project: try savedProject("Picked"), image: try savedImage())
        defer { remove(picks.project); remove(picks.image) }
        let shown = try await bringUp(dialog, in: controller)
        let picker = try #require(shown.controller as? UIDocumentPickerViewController)
        let url = dialog == "Open Project" ? picks.project : picks.image
        if pickedAsItGoes {
            picker.dismiss(animated: true)
            try #require(picker.isBeingDismissed)
            controller.documentPicker(picker, didPickDocumentsAt: [url])
        } else {
            try await end(dialog, shown, ok: true, picks: picks, front: tab, in: controller)
        }
        try await eventually { controller.presentedViewController == nil && tab.document != nil }
        #expect(controller.presentedViewController == nil)
        #expect(controller.tabs.count == 1 && controller.activeTab === tab)
        if dialog == "Open Project" {
            #expect(tab.url?.standardizedFileURL == picks.project.standardizedFileURL)
        } else {
            #expect(tab.session.document?.layers.count == 1 && tab.document != nil)
        }
        await cleanUp(controller)
    }
}
