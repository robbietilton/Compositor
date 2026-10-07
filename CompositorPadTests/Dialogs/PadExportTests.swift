import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// What shows something over the window from the tools, their options and the Layers panel, by the names the tests go
/// by: the rail's colors and the mask's choice, the Brush and Shape bars' colors, the Type bar's font and color, and the
/// Layers panel's Rename….
private let presenters = ["Foreground color", "Background color", "Mask color", "Brush color", "Fill color", "Font", "Text color",
                          "Rename Layer"]

/// Exporting on iPad: the Mac's Export JPEG dialog, the project while it's open, and the window while an export is under
/// way.
@MainActor struct PadExportTests {
    /// A 64 × 48 image, clear but for an opaque red quarter.
    private func raster() throws -> ExportRaster {
        let context = try BrushRaster.context(width: 64, height: 48, mask: false)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return ExportRaster(image: try #require(context.makeImage()))
    }

    /// The color of `image` at (`x`, `y`) from its top left, in 0...255.
    private func color(of image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    /// The dialog starts at the quality last exported, in hundredths as the Mac's slider steps; Export hands over the JPEG
    /// encoded at the quality chosen, which the next export starts from.
    @Test func theDialogStartsAtTheQualityLastExported() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: JPEGExportController.qualityKey)
        defer { defaults.set(saved, forKey: JPEGExportController.qualityKey) }
        defaults.set(0.6, forKey: JPEGExportController.qualityKey)
        var exported: Data?
        let dialog = JPEGExportController(raster: try raster()) { exported = $0 }
        dialog.loadViewIfNeeded()
        #expect(dialog.options.quality == 0.6)

        dialog.chooseQuality(0.734)
        #expect(dialog.options.quality == 0.73)
        await dialog.encoding?.value
        dialog.export()
        let data = try #require(exported)
        #expect(data.starts(with: [0xFF, 0xD8]))
        #expect(defaults.double(forKey: JPEGExportController.qualityKey) == 0.73)
    }

    /// Nothing is exported before the preview is up to date with the settings, and Cancel hands over nothing.
    @Test func exportWaitsForThePreview() async throws {
        var finished: [Data?] = []
        let dialog = JPEGExportController(raster: try raster()) { finished.append($0) }
        dialog.loadViewIfNeeded()
        dialog.export()
        #expect(finished.isEmpty)
        await dialog.encoding?.value
        dialog.cancel()
        #expect(finished.count == 1 && finished[0] == nil)
    }

    /// The image's transparent areas take the color chosen for them.
    @Test func transparentAreasTakeTheColorChosen() async throws {
        let dialog = JPEGExportController(raster: try raster()) { _ in }
        dialog.loadViewIfNeeded()
        dialog.chooseMatte(UIColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        await dialog.encoding?.value

        let preview = try #require(dialog.result?.preview)
        let clear = color(of: preview, x: 48, y: 36)
        #expect(clear.blue > 240 && clear.red < 16 && clear.green < 16)
    }

    /// Export JPEG holds the project while its dialog is open, as on the Mac, so another export waits.
    @Test func theProjectWaitsForTheDialog() throws {
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        session.createNewProject(width: 100, height: 100)
        #expect(window.canPerformAction(#selector(EditorWindowController.exportJPEG(_:)), withSender: nil))

        window.exportJPEG(nil)
        #expect(session.isProjectBusy)
        #expect(!window.canPerformAction(#selector(EditorWindowController.exportPNG(_:)), withSender: nil))
    }

    // MARK: The window while an export is under way

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Waits up to ten seconds for `condition`, as the window's own tasks finish: the system's pickers can take a while
    /// to come up the first time.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A window on the app's screen as the app makes one, the editor in a navigation controller whose bar is its toolbar,
    /// once it has appeared. Its tab in front holds a 200 × 100 project with a gray layer.
    private func shownWindow() async throws -> (window: UIWindow, controller: EditorWindowController, tab: EditorTab) {
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
        tab.session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        tab.session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        return (window, controller, tab)
    }

    /// Takes away whatever is over the window and closes its tabs.
    private func cleanUp(_ controller: EditorWindowController) async {
        controller.presentedViewController?.dismiss(animated: false)
        for tab in controller.tabs { await tab.close() }
    }

    /// What's over the window, once it's up.
    private func shown(over controller: EditorWindowController) async throws -> UIViewController {
        try await eventually { controller.presentedViewController.map { !$0.isBeingPresented && !$0.isBeingDismissed } == true }
        let shown = try #require(controller.presentedViewController)
        shown.view.layoutIfNeeded()
        return shown
    }

    /// The button titled `title` in `controller`'s view.
    private func button(_ title: String, in controller: UIViewController) throws -> UIButton {
        try #require(views(UIButton.self, in: controller.view).first { $0.configuration?.title == title }, "\(title)")
    }

    /// Puts the share sheet away as UIKit does once a tap off it puts it away, or once what's chosen in it is done: it
    /// goes, then says so, with whether the file was shared.
    private func finish(_ share: UIActivityViewController, completed: Bool) async throws {
        share.presentingViewController?.dismiss(animated: true)
        try await eventually { share.presentingViewController == nil }
        share.completionWithItemsHandler?(completed ? .saveToCameraRoll : nil, completed, nil, nil)
    }

    /// Ends what an export shows: the share sheet put away, or the dialog's Cancel.
    private func dismissExport(_ shown: UIViewController) async throws {
        if let share = shown as? UIActivityViewController {
            try await finish(share, completed: false)
        } else {
            try button("Cancel", in: try #require(shown as? JPEGExportController)).sendActions(for: .primaryActionTriggered)
        }
    }

    /// Starts `export`, from the menu bar's command.
    private func start(_ export: String, in controller: EditorWindowController) throws {
        let action = export == "Export JPEG" ? #selector(EditorWindowController.exportJPEG(_:)) : #selector(EditorWindowController.exportPNG(_:))
        try #require(controller.canPerformAction(action, withSender: nil), "\(export)")
        controller.perform(action, with: nil)
    }

    /// Readies the tab for `presenter`: a mask to paint, for its choice, and the Type tool, for its bar.
    private func ready(_ presenter: String, in session: EditorSession) throws {
        switch presenter {
        case "Mask color":
            session.addMask(revealing: true)
            session.selectLayerTarget(try #require(session.activeLayerID), mask: true)
        case "Brush color": session.selectTool(.brush)
        case "Fill color": session.selectTool(.shape)
        case "Font", "Text color": session.selectTool(.type)
        default: break
        }
    }

    /// The control that asks for `presenter`, as the window shows it now, or the Layers panel's menu item.
    private func asker(for presenter: String, in controller: EditorWindowController) throws -> (control: UIControl?, item: UIAction?) {
        controller.updatePropertiesIfNeeded()
        let rail = try #require(views(ToolRailView.self, in: controller.view).first)
        let bar = try #require(views(ToolOptionsBar.self, in: controller.view).first)
        let panel = try #require(views(LayersPanelView.self, in: controller.view).first)
        for view in [rail, bar, panel] as [UIView] { view.updatePropertiesIfNeeded() }
        switch presenter {
        case "Foreground color", "Background color", "Mask color":
            let label = presenter == "Background color" ? "Background color" : "Foreground color"
            let swatch = try #require(views(UIControl.self, in: rail).first { $0.accessibilityLabel == label })
            return (swatch, nil)
        case "Brush color", "Fill color", "Font", "Text color":
            let label = presenter == "Brush color" ? "Foreground color" : presenter
            let control = try #require(views(UIControl.self, in: bar).first { $0.accessibilityLabel == label })
            return (control, nil)
        default:
            let session = try #require(controller.activeTab?.session), id = try #require(session.activeLayerID)
            let items = panel.menu(for: id, in: session).children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }
            return (nil, try #require(items.compactMap { $0 as? UIAction }.first { $0.title == "Rename…" }))
        }
    }

    /// Whether what asks for `presenter` is dimmed, and looks it: a swatch fades, where a button greys by itself.
    private func isDimmed(_ presenter: String, in controller: EditorWindowController) throws -> Bool {
        let asker = try asker(for: presenter, in: controller)
        guard let control = asker.control else { return asker.item?.attributes.contains(.disabled) == true }
        if !(control is UIButton) { #expect((control.alpha < 1) == !control.isEnabled, "\(presenter) looks as it is") }
        return !control.isEnabled
    }

    /// Asks for `presenter` as a finger does, dimmed or not.
    private func ask(for presenter: String, in controller: EditorWindowController) throws {
        let asker = try asker(for: presenter, in: controller)
        asker.control?.sendActions(for: .primaryActionTriggered)
        asker.item?.performWithSender(nil, target: nil)
    }

    /// Whether `shown` is what `presenter` shows.
    private func isShown(_ presenter: String, _ shown: UIViewController) -> Bool {
        switch presenter {
        case "Foreground color", "Background color", "Brush color", "Fill color", "Text color": shown is UIColorPickerViewController
        case "Mask color": (shown as? UIAlertController)?.title == "Mask foreground"
        case "Font": shown is UIFontPickerViewController
        default: (shown as? UIAlertController)?.title == "Rename Layer"
        }
    }

    /// The rail's colors and the mask's choice, the bars' colors and font, and the Layers panel's Rename… show
    /// nothing while an export is under way, whose dialog or share sheet couldn't come up over what they'd show, nor over
    /// anything else the window shows, as the menu bar's commands that show something don't: they're dimmed, and asked
    /// for anyway, they show nothing. The export's dialog or share sheet comes up, or what was over the window stays;
    /// once it has gone, they're there again.
    @Test(arguments: presenters, ["Export PNG", "Export JPEG", "Error"])
    func whatShowsSomethingWaitsForTheWindow(_ presenter: String, _ occupier: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try ready(presenter, in: tab.session)
        #expect(try !isDimmed(presenter, in: controller))
        var over: UIViewController?
        if occupier == "Error" {
            tab.session.brushError = "The brush ran out of room."
            over = try await shown(over: controller)
        } else {
            try start(occupier, in: controller)
        }

        #expect(try isDimmed(presenter, in: controller))
        try ask(for: presenter, in: controller)
        let shown = try await shown(over: controller)
        if let over {
            #expect(shown === over && shown.presentedViewController == nil)
        } else {
            try #require(occupier == "Export JPEG" ? shown is JPEGExportController : shown is UIActivityViewController, "\(shown)")
        }
        if over != nil { shown.dismiss(animated: true) } else { try await dismissExport(shown) }
        try await eventually { controller.presentedViewController == nil }

        #expect(try !isDimmed(presenter, in: controller))
        try ask(for: presenter, in: controller)
        #expect(isShown(presenter, try await self.shown(over: controller)))
        await cleanUp(controller)
    }

    /// A picker the tools or their options opened leaves them as they look, the rail's swatches and what opened it
    /// dimmed by nothing, as they show its color as it's picked; nothing in them can be reached under it.
    @Test(arguments: presenters.filter { $0 != "Rename Layer" })
    func aPickerLeavesWhatOpensThePickersAsItLooks(_ presenter: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try ready(presenter, in: tab.session)
        try ask(for: presenter, in: controller)
        let picker = try await shown(over: controller)
        try #require(isShown(presenter, picker), "\(picker)")

        // As a color is picked, and whenever else the rail and the bar look again.
        if let colors = picker as? UIColorPickerViewController {
            colors.delegate?.colorPickerViewController?(colors, didSelect: .red, continuously: true)
        }
        for view in views(ToolRailView.self, in: controller.view) as [UIView] + views(ToolOptionsBar.self, in: controller.view) {
            view.setNeedsUpdateProperties()
        }
        for asker in [presenter, "Foreground color", "Background color"] {
            #expect(try !isDimmed(asker, in: controller), "\(asker)")
        }
        await cleanUp(controller)
    }

    /// The rail's other color, asked for anyway under a color picker the rail or the Brush or Shape bar opened, shows
    /// nothing more over it, and leaves the picker painting the color it opened for.
    @Test(arguments: ["Foreground color", "Background color", "Brush color", "Fill color"])
    func aColorPickerKeepsToItsColorAsTheOtherIsAskedFor(_ presenter: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let session = tab.session
        try ready(presenter, in: session)
        try ask(for: presenter, in: controller)
        let picker = try #require(try await shown(over: controller) as? UIColorPickerViewController)
        let background = presenter == "Background color"
        let other = session.paletteColor(background: !background)

        try ask(for: background ? "Foreground color" : "Background color", in: controller)
        #expect(controller.presentedViewController === picker && picker.presentedViewController == nil)
        picker.delegate?.colorPickerViewController?(picker, didSelect: .red, continuously: true)
        let picked = session.paletteColor(background: background)
        #expect(picked.red > 0.99 && picked.green < 0.01 && picked.blue < 0.01, "\(picked)")
        #expect(session.paletteColor(background: !background) == other)
        await cleanUp(controller)
    }

    /// What opens the pickers is dimmed while a picker it opened goes, put away by a tap off it or by the font picker
    /// once a font is chosen, as nothing more can come up over the window until it has gone; then it's there again.
    @Test(arguments: presenters.filter { $0 != "Rename Layer" })
    func whatOpensThePickersIsDimmedWhileAPickerGoes(_ presenter: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try ready(presenter, in: tab.session)
        try ask(for: presenter, in: controller)
        let picker = try await shown(over: controller)
        try #require(isShown(presenter, picker), "\(picker)")
        try await eventually { controller.view.tintAdjustmentMode == .dimmed }

        // As UIKit puts it away: the window's tint comes back as it begins to go.
        picker.presentingViewController?.dismiss(animated: true)
        try await eventually { controller.view.tintAdjustmentMode != .dimmed || !picker.isBeingDismissed }
        try #require(picker.isBeingDismissed)
        for asker in [presenter, "Foreground color", "Background color"] {
            #expect(try isDimmed(asker, in: controller), "\(asker)")
        }
        try await eventually { controller.presentedViewController == nil && (try? isDimmed(presenter, in: controller)) == false }
        for asker in [presenter, "Foreground color", "Background color"] {
            #expect(try !isDimmed(asker, in: controller), "\(asker)")
        }
        try ask(for: presenter, in: controller)
        #expect(isShown(presenter, try await self.shown(over: controller)))
        await cleanUp(controller)
    }

    /// Rename… from a menu shows its prompt once the menu has gone, as a menu's choice comes as it goes, though the
    /// window hasn't looked again since the menu came up: a menu goes without the window's tint saying so.
    @Test func renameFromAMenuShowsItsPromptAsTheMenuGoes() async throws {
        let (window, controller, _) = try await shownWindow()
        defer { window.isHidden = true }
        // The row's menu, made as a long press opens it, over a clear window.
        let rename = try #require(try asker(for: "Rename Layer", in: controller).item)
        try #require(!rename.attributes.contains(.disabled))
        let button = try layersButton("New adjustment layer", in: controller)
        button.performPrimaryAction()
        _ = try await shown(over: controller)
        controller.setNeedsUpdateProperties()
        controller.updatePropertiesIfNeeded()

        try #require(button.contextMenuInteraction).dismissMenu()
        for _ in 0..<2000 where controller.presentedViewController != nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(controller.presentedViewController == nil)
        rename.performWithSender(nil, target: nil)
        #expect((controller.presentedViewController as? UIAlertController)?.title == "Rename Layer")
        await cleanUp(controller)
    }

    /// The Layers panel's button for `title`, as the panel shows it now.
    private func layersButton(_ title: String, in controller: EditorWindowController) throws -> UIButton {
        for panel in views(LayersPanelView.self, in: controller.view) { panel.updatePropertiesIfNeeded() }
        return try #require(views(UIButton.self, in: controller.view).first { $0.accessibilityLabel == title }, "\(title)")
    }

    /// Export JPEG's dialog waits for what came up over the window as the export made its image, as a menu, rather than
    /// being dropped: the window stays on its tab, the project held, however often it looks again, until the menu is put
    /// away; then the dialog comes up, and its Cancel lets the project go.
    @Test func theJPEGDialogWaitsForAMenu() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try start("Export JPEG", in: controller)
        let button = try layersButton("New adjustment layer", in: controller)
        button.performPrimaryAction()
        let menu = try await shown(over: controller)
        await controller.makingExport?.value
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController === menu && tab.session.isProjectBusy)

        try #require(button.contextMenuInteraction).dismissMenu()
        try await eventually { controller.presentedViewController is JPEGExportController }
        let dialog = try await shown(over: controller)
        try #require(dialog is JPEGExportController)
        try await dismissExport(dialog)
        try await eventually { controller.presentedViewController == nil }
        #expect(!tab.session.isProjectBusy)
        await cleanUp(controller)
    }

    /// The window going while Export JPEG's dialog waits for a menu lets the project go, as the dialog's Cancel would,
    /// so every project is saved and closed; the dialog doesn't come up once the menu goes.
    @Test func theWindowGoingWhileTheJPEGDialogWaitsClosesEveryProject() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try await tab.createDocument(named: "PadExportTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        tab.session.addBlankLayer()
        let layers = try #require(tab.session.document?.layers.count)
        try start("Export JPEG", in: controller)
        let button = try layersButton("New adjustment layer", in: controller)
        button.performPrimaryAction()
        let menu = try await shown(over: controller)
        await controller.makingExport?.value
        #expect(controller.presentedViewController === menu && tab.session.isProjectBusy)

        controller.closeAll()
        try await eventually { tab.document == nil }
        #expect(tab.document == nil && !tab.session.isProjectBusy)
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == layers)
        try #require(button.contextMenuInteraction).dismissMenu()
        try await eventually { controller.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController == nil)
    }
}
