import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Compositor

/// An adjustment's editor and the window's tabs on iPad. The editor edits the project of the tab it opened over, so it
/// keeps the window on that tab until it's done, as the Mac's panels keep theirs: what would bring another tab forward
/// or close one is dimmed meanwhile, and a project opened from elsewhere opens behind, coming forward once it's done.
@MainActor struct PadEditorTabsTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Waits up to a few seconds for `condition`, as the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A 200 × 100 project of one gray layer, in `session`.
    private func fill(_ session: EditorSession) throws {
        session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
    }

    /// A window on the app's screen as the app makes one, the editor in a navigation controller whose bar is its toolbar,
    /// once it has appeared. Its tab in front holds a project of one gray layer, with a file of its own unless
    /// `withFile` is off.
    private func shownWindow(withFile: Bool = true) async throws -> (window: UIWindow, controller: EditorWindowController,
                                                                     tab: EditorTab) {
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
        try fill(tab.session)
        if withFile { try await tab.createDocument(named: "PadEditorTabsTests \(UUID().uuidString)") }
        return (window, controller, tab)
    }

    /// A second tab with a project of its own, behind the one in front.
    private func tabBehind(in controller: EditorWindowController) throws -> EditorTab {
        let front = try #require(controller.activeTab)
        controller.newCanvasTab(nil)
        let tab = try #require(controller.activeTab)
        try #require(tab !== front)
        try fill(tab.session)
        controller.select(front.id)
        try #require(controller.activeTab === front)
        return tab
    }

    /// A project of one layer saved in a folder of its own, as another app hands it over.
    private func savedProject(_ name: String = "Project") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PadEditorTabsTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let session = EditorSession()
        try fill(session)
        let url = folder.appending(path: name + ".comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// Writes a project of two layers over the package at `url`, as another app would: through a file coordinator,
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

    // MARK: Opening an editor

    /// Opens the editor `entry` names over the tab in front, as the menu bar does, or the Layers panel for a new
    /// adjustment layer's.
    private func open(_ entry: String, in controller: EditorWindowController) throws {
        typealias Window = EditorWindowController
        switch entry {
        case "Gaussian Blur":
            let command = UICommand(title: "Gaussian Blur…", action: #selector(Window.applyFilter(_:)),
                                    propertyList: FilterKind.gaussianBlur.rawValue)
            try #require(controller.canPerformAction(command.action, withSender: command))
            controller.perform(command.action, with: command)
        case "Levels", "Curves", "Hue/Saturation":
            let action = entry == "Levels" ? #selector(Window.levels(_:))
                : entry == "Curves" ? #selector(Window.curves(_:)) : #selector(Window.hueSaturation(_:))
            try #require(controller.canPerformAction(action, withSender: nil))
            controller.perform(action, with: nil)
        default:
            for panel in views(LayersPanelView.self, in: controller.view) { panel.updatePropertiesIfNeeded() }
            let button = try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == "New adjustment layer" })
            let levels = try #require(button.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == "Levels" })
            levels.performWithSender(nil, target: nil)
        }
    }

    /// The adjustment's editor over the window, once it shows.
    private func editor(over controller: EditorWindowController) async throws -> AdjustmentEditorController {
        func shown() -> AdjustmentEditorController? {
            (controller.presentedViewController as? AdjustmentEditorController).flatMap { $0 is EffectEditorController ? nil : $0 }
        }
        try await eventually { shown() != nil && shown()?.isBeingPresented == false }
        let editor = try #require(shown())
        editor.view.layoutIfNeeded()
        return editor
    }

    /// Taps the editor's OK, or its Cancel.
    private func tap(ok: Bool, in editor: AdjustmentEditorController) throws {
        let title = ok ? "OK" : "Cancel"
        let button = try #require(views(UIButton.self, in: editor.view).first { $0.configuration?.title == title }, "\(title)")
        button.sendActions(for: .primaryActionTriggered)
    }

    /// Ends the editor with its OK, or its Cancel, as a finger does, and waits for it to go.
    private func end(_ editor: AdjustmentEditorController, ok: Bool, over controller: EditorWindowController) async throws {
        try tap(ok: ok, in: editor)
        try await eventually { controller.presentedViewController == nil }
        try #require(controller.presentedViewController == nil)
    }

    /// Shows an alert over the window, as one saying a save failed.
    private func showAlert(over controller: EditorWindowController) -> UIAlertController {
        let alert = UIAlertController(title: "Couldn’t save the project", message: "The disk is full.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: false)
        return alert
    }

    /// The menu bar's commands that open an adjustment's editor: for a layer's pixels, Levels…, Curves… and
    /// Hue/Saturation… from the Image menu, a filter, and a new Levels adjustment layer; and Edit Adjustment…, for an
    /// adjustment layer.
    private func editorCommands() throws -> (pixels: [UICommand], layer: UICommand) {
        let bar = MenuBarModel.built(by: AppDelegate())
        let image = try #require(bar.menu(titled: "Image")).commands, filter = try #require(bar.menu(titled: "Filter")).commands
        let layer = try #require(bar.menu(titled: "Layer"))
        let new = try #require(layer.submenus.first { $0.title == "New Adjustment Layer" }).commands
        let pixels = [image.first { $0.title == "Levels…" }, image.first { $0.title == "Curves…" },
                      image.first { $0.title == "Hue/Saturation…" }, filter.first { $0.title == "Gaussian Blur…" },
                      new.first { $0.title == "Levels…" }].compactMap { $0 }
        try #require(pixels.count == 5)
        return (pixels, try #require(layer.commands.first { $0.title == "Edit Adjustment…" }))
    }

    // MARK: What waits

    /// The menu bar's commands that would bring another tab forward or close one, and those that show something the
    /// editor would have to give way to: New Canvas…, Open Project…, a project in Open Recent, the imports, Duplicate,
    /// Rename… and Close Tab.
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

    /// The actions of the tab's context menu, as a long press on it shows them.
    private func menuActions(of tab: EditorTab, in strip: TabStripView) throws -> [UIAction] {
        func actions(_ menu: UIMenu) -> [UIAction] {
            menu.children.flatMap { child -> [UIAction] in
                if let menu = child as? UIMenu { return actions(menu) }
                return (child as? UIAction).map { [$0] } ?? []
            }
        }
        return actions(try #require(strip.menu(tab.id)))
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
            // VoiceOver says which tab is in front, and that the others are dimmed.
            let traits = pill.accessibilityTraits
            #expect(traits.contains(.notEnabled) == dimmed && traits.contains(.selected) == (tab === front),
                    "\(pill.accessibilityLabel ?? "")", sourceLocation: sourceLocation)
            let actions = try menuActions(of: tab, in: strip)
            #expect(!actions.isEmpty && actions.allSatisfy { $0.attributes.contains(.disabled) == !free },
                    "\(actions.map(\.title))", sourceLocation: sourceLocation)
        }
        for close in closes { #expect(close.isEnabled == free, "\(close.accessibilityLabel ?? "")", sourceLocation: sourceLocation) }
    }

    /// While an adjustment's editor is open, from the moment it's asked for (an adjustment layer's, before it has the
    /// pixels beneath it and shows), what would bring another tab forward or close one is dimmed, as on the Mac, and so
    /// is what would have to show over it; all of it is back once OK or Cancel ends the editor.
    @Test(arguments: ["Levels", "Curves", "Hue/Saturation", "Gaussian Blur", "Levels layer"], [true, false])
    func whatWouldLeaveTheEditorIsDimmed(_ entry: String, ok: Bool) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        _ = try tabBehind(in: controller)
        try expectTabs(free: true, in: controller, front: tab)

        try open(entry, in: controller)
        try expectTabs(free: false, in: controller, front: tab)
        let editor = try await editor(over: controller)
        #expect(editor.session === tab.session)
        try expectTabs(free: false, in: controller, front: tab)

        try await end(editor, ok: ok, over: controller)
        #expect(controller.activeTab === tab)
        try expectTabs(free: true, in: controller, front: tab)
        await cleanUp(controller)
    }

    /// Beside an effect's panel nothing waits: the panel gives way to another tab, its effect kept as its OK keeps
    /// it, as before.
    @Test func anEffectsPanelStillGivesWayToAnotherTab() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        _ = try tabBehind(in: controller)
        for panel in views(LayersPanelView.self, in: controller.view) { panel.updatePropertiesIfNeeded() }
        let effects = try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == "Layer effects" })
        let stroke = try #require(effects.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == LayerEffectKind.stroke.rawValue + "…" })
        stroke.performWithSender(nil, target: nil)
        try await eventually { controller.presentedViewController is EffectEditorController }
        try #require(controller.presentedViewController is EffectEditorController)
        try expectTabs(free: true, in: controller, front: tab)

        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened.url == url && controller.activeTab === opened)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        #expect(tab.session.effectsEditing == nil && tab.session.document?.layers.contains { $0.effects?.stroke != nil } == true)
        try await eventually { opened.document != nil }
        await cleanUp(controller)
    }

    /// No adjustment's editor opens under anything else over the window, as an alert, which it couldn't come over: the
    /// commands that open one are dimmed, as Rename Layer is, rather than holding the window on its tab for an editor
    /// that can't show yet. They're back once the alert has gone, and so is what switches tabs.
    @Test func noEditorOpensUnderAnAlert() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        _ = try tabBehind(in: controller)
        let session = tab.session
        let gray = try #require(session.activeLayerID)
        // A Levels adjustment layer, not being edited, for Edit Adjustment.
        session.addAdjustment(.levels)
        session.adjustmentEditingID = nil
        let layer = try #require(session.activeLayerID)
        try #require(layer != gray && session.activeLayer?.adjustment?.kind == .levels)
        let (pixels, edit) = try editorCommands()
        func expectEditors(free: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            session.selectLayer(gray)
            for command in pixels {
                #expect(controller.canPerformAction(command.action, withSender: command) == free, "\(command.title)",
                        sourceLocation: sourceLocation)
            }
            session.selectLayer(layer)
            #expect(controller.canPerformAction(edit.action, withSender: edit) == free, "\(edit.title)", sourceLocation: sourceLocation)
        }
        expectEditors(free: true)

        let alert = showAlert(over: controller)
        try await eventually { controller.presentedViewController === alert && !alert.isBeingPresented }
        expectEditors(free: false)
        alert.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }
        expectEditors(free: true)
        #expect(session.levels == nil && session.adjustmentEditingID == nil)
        try expectTabs(free: true, in: controller, front: tab)
        await cleanUp(controller)
    }

    /// An adjustment's edit begun while something else is over the window, as a question that came up while an
    /// adjustment layer got the pixels beneath it, gets its editor once that has gone, rather than holding the window on
    /// its tab with nothing to show.
    @Test func anEditBegunUnderAnAlertGetsItsEditorOnceItsGone() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        _ = try tabBehind(in: controller)
        try open("Levels layer", in: controller)
        let alert = showAlert(over: controller)
        try await eventually { tab.session.levels != nil }
        try #require(tab.session.levels != nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController === alert)
        try expectTabs(free: false, in: controller, front: tab)

        alert.dismiss(animated: false)
        let editor = try await editor(over: controller)
        #expect(editor.session === tab.session && controller.activeTab === tab)
        try await end(editor, ok: false, over: controller)
        try expectTabs(free: true, in: controller, front: tab)
        await cleanUp(controller)
    }

    // MARK: Projects opened meanwhile

    /// Levels open on the tab in front, with a change to apply.
    private func levelsToApply(in controller: EditorWindowController) async throws -> AdjustmentEditorController {
        try open("Levels", in: controller)
        let editor = try await editor(over: controller)
        var settings = try #require(editor.session.levels?.settings)
        settings.current = LevelsEditorController.range(settings.current, input: 0, at: 40)
        editor.session.updateLevels(settings, preview: true)
        return editor
    }

    /// A project opened from elsewhere while an editor is open, from Files or Open in Compositor, opens at once in a
    /// tab behind, dimmed as the others are, the editor staying on its own tab; once the editor's OK has applied its
    /// edit, or its Cancel let it go, the project comes forward.
    @Test(arguments: [true, false])
    func aProjectOpenedFromElsewhereOpensBehind(ok: Bool) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let editor = try await levelsToApply(in: controller)
        let url = try savedProject()
        defer { remove(url) }

        // As the scene hands it over.
        controller.open([url])
        #expect(controller.tabs.count == 2)
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && opened.url == url)
        #expect(controller.activeTab === tab && controller.presentedViewController === editor && editor.session === tab.session)
        let (_, pills, _) = try tabStrip(of: controller)
        #expect(pills.count == 2 && pills.last?.isEnabled == false)
        try await eventually { opened.document != nil }
        #expect(opened.document != nil)
        #expect(controller.activeTab === tab && controller.presentedViewController === editor && tab.session.levels != nil)

        try await end(editor, ok: ok, over: controller)
        try await eventually { controller.activeTab === opened }
        #expect(controller.activeTab === opened)
        #expect(tab.session.levels == nil)
        if ok { #expect(tab.session.history.undoName == "Levels") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.presentedViewController == nil && controller.activeTab === opened)
        try expectTabs(free: true, in: controller, front: opened)
        await cleanUp(controller)
    }

    /// A project opened from elsewhere that's open in a tab behind comes forward once the editor is done.
    @Test func aProjectOpenBehindComesForwardOnceTheEditorIsDone() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let behind = try #require(controller.activeTab)
        try await eventually { behind.document != nil }
        try tabStrip(of: controller).strip.onSelect(tab.id)
        try #require(controller.activeTab === tab)
        try open("Hue/Saturation", in: controller)
        let editor = try await editor(over: controller)

        controller.open([url])
        #expect(controller.tabs.count == 2)
        #expect(controller.activeTab === tab && controller.presentedViewController === editor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.activeTab === tab && controller.presentedViewController === editor)

        try await end(editor, ok: false, over: controller)
        try await eventually { controller.activeTab === behind }
        #expect(controller.activeTab === behind)
        await cleanUp(controller)
    }

    /// Another window opening a project open in this one, as it does for a project from Files, waits as well: the
    /// project's tab here comes forward once this window's editor is done, and the other window opens nothing.
    @Test func anotherWindowsOpenWaitsForTheEditor() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let behind = try #require(controller.activeTab)
        try await eventually { behind.document != nil }
        controller.select(tab.id)
        try open("Gaussian Blur", in: controller)
        let editor = try await editor(over: controller)

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
        #expect(controller.activeTab === tab && controller.presentedViewController === editor && editor.session === tab.session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.activeTab === tab && controller.presentedViewController === editor)

        try await end(editor, ok: true, over: controller)
        try await eventually { controller.activeTab === behind }
        #expect(controller.activeTab === behind)
        await cleanUp(controller)
        await cleanUp(other)
    }

    /// Several projects opened from elsewhere while the editor is open all open behind; the last asked for comes
    /// forward once the editor is done.
    @Test func severalOpenBehindAndTheLastComesForward() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try open("Levels layer", in: controller)
        let urls = try ["First", "Second", "Third"].map(savedProject)
        defer { urls.forEach(remove) }

        controller.open([urls[0]])
        controller.open([urls[1], urls[2]])
        #expect(controller.tabs.map(\.url) == [tab.url] + urls)
        let opened = Array(controller.tabs.dropFirst())
        #expect(controller.activeTab === tab)
        let editor = try await editor(over: controller)
        #expect(editor.session === tab.session && controller.activeTab === tab)
        try await eventually { controller.tabs.allSatisfy { $0.document != nil } }

        try await end(editor, ok: false, over: controller)
        try await eventually { controller.activeTab === opened.last }
        #expect(controller.activeTab === opened.last)
        await cleanUp(controller)
    }

    /// When the last asked for is the project in front, opened from elsewhere again after one open behind, it stays in
    /// front once the editor is done.
    @Test func theProjectInFrontAskedForLastStays() async throws {
        let (window, controller, behind) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        controller.open([url])
        let front = try #require(controller.activeTab)
        try await eventually { front.document != nil }
        try open("Curves", in: controller)
        let editor = try await editor(over: controller)

        controller.open([try #require(behind.url)])
        controller.open([url])
        #expect(controller.tabs.count == 2)
        #expect(controller.activeTab === front && controller.presentedViewController === editor)

        try await end(editor, ok: false, over: controller)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.activeTab === front)
        await cleanUp(controller)
    }

    /// Work that finishes while an editor is open, as a Duplicate's copy, opens behind as well, and comes forward once
    /// the editor is done.
    @Test func aDuplicateFinishedMeanwhileOpensBehind() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let duplicate = #selector(EditorWindowController.duplicateProject(_:))
        try #require(controller.canPerformAction(duplicate, withSender: nil))
        controller.perform(duplicate, with: nil)
        try open("Curves", in: controller)
        let editor = try await editor(over: controller)

        try await eventually { controller.tabs.count == 2 && controller.tabs.last?.document != nil }
        let copy = try #require(controller.tabs.last)
        #expect(copy !== tab && copy.document != nil)
        #expect(controller.activeTab === tab && controller.presentedViewController === editor && editor.session === tab.session)

        try await end(editor, ok: false, over: controller)
        try await eventually { controller.activeTab === copy }
        #expect(controller.activeTab === copy)
        await cleanUp(controller)
    }

    /// An adjustment's edit that ends without its editor ever showing, as one of a kind the iPad has no editor for, lets
    /// the tab asked for meanwhile come forward too.
    @Test func anEditEndedBeforeItsEditorShowedLetsTheTabAskedForComeForward() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let url = try savedProject()
        defer { remove(url) }
        tab.session.addAdjustment(.invert)
        let invert = try #require(tab.session.activeLayerID)
        tab.session.adjustmentEditingID = invert

        controller.open([url])
        let opened = try #require(controller.tabs.last)
        #expect(opened !== tab && opened.url == url && controller.activeTab === tab)
        try await eventually { controller.activeTab === opened }
        #expect(controller.activeTab === opened && tab.session.adjustmentEditingID == nil)
        #expect(controller.presentedViewController == nil)
        await cleanUp(controller)
    }

    // MARK: Closing

    /// A tab whose save failed as it closed waits for an editor open over another tab meanwhile to be done: then it
    /// comes forward, saying why, as it would have at once.
    @Test func aClosingTabsFailedSaveWaitsForTheEditor() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
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
        try #require(controller.activeTab === tab)
        try open("Levels", in: controller)
        let editor = try await editor(over: controller)
        // Its save fails meanwhile.
        try await eventually { closing.document?.documentState.contains(.savingError) == true || controller.activeTab !== tab }
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.activeTab === tab && controller.presentedViewController === editor && controller.tabs.contains { $0 === closing })
        #expect(editor.presentedViewController == nil)

        try tap(ok: false, in: editor)
        try await eventually { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == "Couldn’t save the project" && alert.actions.map(\.title) == ["Don’t Save", "Cancel"])
        #expect(controller.activeTab === closing)
        alert.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))
        controller.closeWithoutSaving(closing.id)
        await cleanUp(controller)
    }

    /// So does a closing tab's question about a change made elsewhere; it comes forward after a project opened
    /// meanwhile has, so the question isn't left behind it, with the close waiting for its answer.
    @Test func aClosingTabsQuestionWaitsForTheEditor() async throws {
        let (window, controller, tab) = try await shownWindow()
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

        // Closing settles the transform, and the change asks once Levels is open over the other tab.
        controller.close(closing.id)
        try tabStrip(of: controller).strip.onSelect(tab.id)
        try #require(controller.activeTab === tab)
        try open("Levels", in: controller)
        let editor = try await editor(over: controller)
        try await eventually { closing.session.changedOnDisk }
        try #require(closing.session.changedOnDisk)
        let other = try savedProject("Other")
        defer { remove(other) }
        controller.open([other])
        #expect(controller.tabs.last?.url == other)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.activeTab === tab && controller.presentedViewController === editor)

        try tap(ok: false, in: editor)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == "“Project.comp” was changed on disk.")
        #expect(controller.activeTab === closing)
        controller.presentedViewController?.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }
        document.answerChangeOnDisk(revert: true)
        try await eventually { !controller.tabs.contains { $0 === closing } }
        #expect(!controller.tabs.contains { $0 === closing })
        await cleanUp(controller)
    }

    /// A tab closed with its editor open doesn't hold the window: the tab beside it comes forward, at once when the
    /// closed tab has no file to save, or when asked for while it saves, and the editor goes with its tab, as closing
    /// cancels it.
    @Test(arguments: [true, false])
    func aTabClosedWithItsEditorLeavesTheNextInFront(withFile: Bool) async throws {
        let (window, controller, tab) = try await shownWindow(withFile: withFile)
        defer { window.isHidden = true }
        let next = try tabBehind(in: controller)
        let file = tab.document?.fileURL
        defer { if let file { try? FileManager.default.removeItem(at: file) } }
        try open("Hue/Saturation", in: controller)
        _ = try await editor(over: controller)

        controller.close(tab.id)
        if withFile { try tabStrip(of: controller).strip.onSelect(next.id) }
        #expect(controller.activeTab === next)
        try await eventually { !controller.tabs.contains { $0 === tab } && controller.presentedViewController == nil }
        #expect(controller.tabs.count == 1 && controller.activeTab === next && controller.presentedViewController == nil)
        try await eventually { tab.session.hueSaturation == nil }
        #expect(tab.session.hueSaturation == nil)
        await cleanUp(controller)
    }

    // MARK: An editor whose edit ended

    /// An editor whose edit ended while another tab was in front goes, rather than staying with a spinner after its OK,
    /// or with buttons that do nothing after its Cancel. Nothing leaves an editor over another tab now, so the state is
    /// set up directly: Levels open on the tab behind, its editor shown over the tab in front, as a switch left it.
    @Test(arguments: [true, false])
    func anEditorWhoseEditEndedBehindGoes(ok: Bool) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let behind = try tabBehind(in: controller)
        behind.session.beginLevels()
        var settings = try #require(behind.session.levels?.settings)
        settings.current = LevelsEditorController.range(settings.current, input: 0, at: 40)
        behind.session.updateLevels(settings, preview: true)
        let editor = LevelsEditorController(session: behind.session)
        editor.modalPresentationStyle = .popover
        editor.popoverPresentationController?.sourceView = controller.view
        controller.present(editor, animated: false)
        try await eventually { controller.presentedViewController === editor && !editor.isBeingPresented }
        // The window looks at what it shows once more, as a switch has it do, and is done with that.
        controller.setNeedsUpdateProperties()
        controller.updatePropertiesIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        try #require(controller.activeTab === tab && controller.presentedViewController === editor)

        try tap(ok: ok, in: editor)
        try await eventually { behind.session.levels == nil }
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        #expect(controller.activeTab === tab && behind.session.levels == nil)
        if ok { #expect(behind.session.history.undoName == "Levels") }
        await cleanUp(controller)
    }
}
