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

    /// The dialog starts at the quality last exported, in hundredths as the Mac's slider steps; Export offers the JPEG
    /// encoded at the quality chosen, which the next export starts from.
    @Test func theDialogStartsAtTheQualityLastExported() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: JPEGExportController.qualityKey)
        defer { defaults.set(saved, forKey: JPEGExportController.qualityKey) }
        defaults.set(0.6, forKey: JPEGExportController.qualityKey)
        var exported: Data?
        let dialog = JPEGExportController(raster: try raster(), share: { exported = $0; return nil }, cancelled: {})
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

    /// Nothing is exported before the preview is up to date with the settings, and Cancel offers nothing.
    @Test func exportWaitsForThePreview() async throws {
        var finished: [Data?] = []
        let dialog = JPEGExportController(raster: try raster(), share: { finished.append($0); return nil }, cancelled: { finished.append(nil) })
        dialog.loadViewIfNeeded()
        dialog.export()
        #expect(finished.isEmpty)
        await dialog.encoding?.value
        dialog.cancel()
        #expect(finished.count == 1 && finished[0] == nil)
    }

    /// The image's transparent areas take the color chosen for them.
    @Test func transparentAreasTakeTheColorChosen() async throws {
        let dialog = JPEGExportController(raster: try raster(), share: { _ in nil }, cancelled: {})
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

    /// Puts the share sheet away as UIKit does once a tap off it puts it away, or once what's chosen in it is done, as
    /// Save Image: the sheet goes, and UIKit tells its handler as it goes, with whether the file was shared.
    private func finish(_ share: UIActivityViewController, completed: Bool) async throws {
        if completed {
            let handler = share.completionWithItemsHandler
            share.completionWithItemsHandler = { _, _, items, error in handler?(.saveToCameraRoll, true, items, error) }
        }
        share.presentingViewController?.dismiss(animated: true)
        try await eventually { share.presentingViewController == nil && !share.isBeingDismissed }
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

    /// What an export shows waits for what came up over the window as the export made its image, as a menu, rather than
    /// being dropped, or refused by UIKit and lost: the window stays on its tab, the project held and the card saying
    /// what it opens, however often the window looks again, until the menu is put away; then Export JPEG's dialog or
    /// Export PNG's share sheet comes up, and the card goes. Once that's put away, the project is free.
    @Test(arguments: ["Export JPEG", "Export PNG"])
    func whatAnExportShowsWaitsForAMenu(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try start(export, in: controller)
        let button = try layersButton("New adjustment layer", in: controller)
        button.performPrimaryAction()
        let menu = try await shown(over: controller)
        await controller.makingExport?.value
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController === menu && tab.session.isProjectBusy)
        let card = try exportCard(in: controller)
        let opening = export == "Export JPEG" ? "Opening the dialog…" : "Opening the share sheet…"
        #expect(!card.isHidden && card.progress?.lines.last == running(opening))

        try #require(button.contextMenuInteraction).dismissMenu()
        let isExports: (UIViewController?) -> Bool = { export == "Export JPEG" ? $0 is JPEGExportController : $0 is UIActivityViewController }
        try await eventually { isExports(controller.presentedViewController) }
        let shown = try await shown(over: controller)
        try #require(isExports(shown), "\(shown)")
        #expect(try exportCard(in: controller).isHidden)
        try await dismissExport(shown)
        try await eventually { controller.presentedViewController == nil }
        try #require(!tab.session.isProjectBusy)
        await cleanUp(controller)
    }

    /// The window going while what an export shows, its dialog or its share sheet, waits for a menu lets the project go,
    /// as a dialog's Cancel would, so every project is saved and closed, the card gone; nothing comes up once the menu
    /// goes.
    @Test(arguments: ["Export JPEG", "Export PNG"])
    func theWindowGoingWhileWhatAnExportShowsWaitsClosesEveryProject(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try await tab.createDocument(named: "PadExportTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        tab.session.addBlankLayer()
        let layers = try #require(tab.session.document?.layers.count)
        try start(export, in: controller)
        let button = try layersButton("New adjustment layer", in: controller)
        button.performPrimaryAction()
        let menu = try await shown(over: controller)
        await controller.makingExport?.value
        #expect(controller.presentedViewController === menu && tab.session.isProjectBusy)

        controller.closeAll()
        try await eventually { tab.document == nil }
        #expect(tab.document == nil && !tab.session.isProjectBusy)
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == layers)
        #expect(try exportCard(in: controller).isHidden)
        try #require(button.contextMenuInteraction).dismissMenu()
        try await eventually { controller.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController == nil)
    }

    /// Export PNG holds the project while it makes its image, as on the Mac and as Export JPEG does: from the moment it's
    /// chosen, nothing else is done to the project, nor does another export or a resize begin; once its share sheet is
    /// up, the project is free.
    @Test func exportPNGHoldsTheProjectWhileItMakesItsImage() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let session = tab.session, layers = session.document?.layers.count
        try start("Export PNG", in: controller)
        #expect(session.isProjectBusy && !session.canEditLayers && !session.canEditPalette)
        for action in [#selector(EditorWindowController.exportJPEG(_:)), #selector(EditorWindowController.imageSize(_:))] {
            #expect(!controller.canPerformAction(action, withSender: nil), "\(action)")
        }
        session.addBlankLayer()
        #expect(session.document?.layers.count == layers)

        let share = try await shown(over: controller)
        try #require(share is UIActivityViewController)
        // Required, as a project left held would hold up closing its tab.
        try #require(!session.isProjectBusy)
        try await dismissExport(share)
        await cleanUp(controller)
    }

    /// An effect's panel goes as an export begins, its effect kept as the panel's OK keeps it, as it goes for anything
    /// else the window shows: the export takes the project as the panel left it, and holds it meanwhile.
    @Test(arguments: ["Export PNG", "Export JPEG"])
    func anEffectsPanelGoesAsAnExportBegins(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let session = tab.session
        let effects = try layersButton("Layer effects", in: controller)
        let stroke = try #require(effects.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == LayerEffectKind.stroke.rawValue + "…" })
        stroke.performWithSender(nil, target: nil)
        let panel = try await shown(over: controller)
        try #require(panel is EffectEditorController)
        let size = try #require(views(SliderField.self, in: panel.view).first { views(UILabel.self, in: $0).first?.text == "Size" })
        size.onChange(9)

        try start(export, in: controller)
        #expect(session.effectsEditing == nil && session.activeLayer?.effects?.stroke?.size == 9)
        try await eventually { !(controller.presentedViewController is EffectEditorController) }
        let shown = try await shown(over: controller)
        #expect(export == "Export JPEG" ? shown is JPEGExportController : shown is UIActivityViewController)
        #expect(session.activeLayer?.effects?.stroke?.size == 9)
        try await dismissExport(shown)
        await cleanUp(controller)
    }

    // MARK: The Export card

    private typealias Line = LoadingProgress.Line
    private func running(_ text: String) -> Line { Line(text: text, isDone: false) }
    private func done(_ text: String) -> Line { Line(text: text, isDone: true) }

    /// Each step of an export has a line once it's reached, as the Loading card's: composing the layers, counting as it
    /// goes, then encoding, then opening what shows the file; the steps done say what they did, and a count said late
    /// doesn't move a line back, nor keep a step under way once a later one is said.
    @Test func theExportCardSaysWhatEachStepHasDone() {
        var steps = ExportProgress.Steps()
        func lines(_ kind: ExportProgress.Kind = .png, opening: Bool = false) -> [Line] {
            ExportProgress.lines(steps, kind: kind, opening: opening)
        }
        #expect(lines() == [running("Waiting to compose the image…")])
        steps.record(.composing(total: 8))
        #expect(lines() == [running("Composing 0/8 layers…")])
        steps.record(.composed(done: 3))
        steps.record(.composed(done: 2))
        #expect(lines() == [running("Composing 3/8 layers…")])
        steps.record(.composed(done: 8))
        #expect(lines() == [done("8/8 layers composed.")])
        steps.record(.encoding)
        #expect(lines() == [done("8/8 layers composed."), running("Encoding PNG…")])
        #expect(lines(.jpeg) == [done("8/8 layers composed."), running("Encoding JPEG…")])
        #expect(lines(opening: true) == [done("8/8 layers composed."), done("PNG encoded."), running("Opening the share sheet…")])
        #expect(lines(.jpeg, opening: true) == [done("8/8 layers composed."), done("JPEG encoded."), running("Opening the dialog…")])

        // A step said, the ones before it are done, should their last counts come after it.
        steps = ExportProgress.Steps()
        steps.record(.composing(total: 8))
        steps.record(.composed(done: 5))
        #expect(lines(opening: true) == [done("8/8 layers composed."), done("PNG encoded."), running("Opening the share sheet…")])
        steps.record(.encoding)
        #expect(lines() == [done("8/8 layers composed."), running("Encoding PNG…")])

        // One layer has no count to show, and none has no line of its own.
        steps = ExportProgress.Steps()
        steps.record(.composing(total: 1))
        #expect(lines() == [running("Composing the layer…")])
        steps.record(.composed(done: 1))
        #expect(lines() == [done("1/1 layer composed.")])
        steps = ExportProgress.Steps()
        steps.record(.composing(total: 0))
        #expect(lines() == [])
        steps.record(.encoding)
        #expect(lines() == [running("Encoding PNG…")])
    }

    /// The card names the project and its format, says the image's size, takes the steps said on the exporter's thread
    /// in the order they were said, ends once, and hears nothing afterwards.
    @Test func theExportCardTakesTheStepsInOrderAndEndsOnce() async throws {
        let progress = ExportProgress(name: "Harbor", kind: .jpeg, width: 4032, height: 3024)
        #expect(progress.title == "Exporting “Harbor” as JPEG…" && progress.caption == "4032 × 3024 px" && progress.isShowing)
        await Task.detached {
            progress.said(.composing(total: 500))
            for done in 1...500 { progress.said(.composed(done: done)) }
            progress.said(.encoding)
        }.value
        try await eventually { progress.lines.count == 2 }
        #expect(progress.lines == [done("500/500 layers composed."), running("Encoding JPEG…")])
        progress.opening()
        progress.ended()
        progress.ended()
        progress.said(.composed(done: 600))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!progress.isShowing && progress.steps.composed == 500 && progress.doneAnnouncement == nil)
    }

    /// The window's Export card, which a tab shows while its export makes its file.
    private func exportCard(in controller: EditorWindowController) throws -> ProgressCardView {
        controller.updatePropertiesIfNeeded()
        let cards = views(ProgressCardView.self, in: controller.view)
        for card in cards { card.updatePropertiesIfNeeded() }
        return try #require(cards.first { $0.progress is ExportProgress } ?? cards.last)
    }

    /// An export's card shows from the moment it's chosen, in the same refresh, over the canvas of the tab it exports,
    /// saying what it exports and how big; it then says each step the export takes, and goes as what it opens comes up:
    /// the share sheet, or the dialog, which opens with the JPEG the card said it encoded, ready to export.
    @Test(arguments: ["Export PNG", "Export JPEG"])
    func theCardShowsFromTheMomentAnExportIsChosen(_ export: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        let format = export == "Export JPEG" ? "JPEG" : "PNG"
        // Nothing else is left for the window to follow.
        controller.updatePropertiesIfNeeded()
        try start(export, in: controller)
        let card = try exportCard(in: controller)
        let progress = try #require(card.progress as? ExportProgress)
        #expect(!card.isHidden && progress.title == "Exporting “\(tab.title)” as \(format)…" && progress.caption == "200 × 100 px")
        #expect(progress.lines == [running("Waiting to compose the image…")])
        #expect(card.convert(card.bounds, to: nil) == tab.canvas.convert(tab.canvas.bounds, to: nil))
        // To VoiceOver, the title is a heading, and the line under way changes often.
        let labels = views(UILabel.self, in: card)
        #expect(labels.first { $0.text == progress.title }?.accessibilityTraits.contains(.header) == true)
        #expect(labels.first { $0.text == "Waiting to compose the image…" }?.accessibilityTraits.contains(.updatesFrequently) == true)

        let shown = try await shown(over: controller)
        #expect(progress.lines == [done("2/2 layers composed."), done("\(format) encoded."),
                                   running(format == "PNG" ? "Opening the share sheet…" : "Opening the dialog…")])
        #expect(try exportCard(in: controller).isHidden && !progress.isShowing)
        if let dialog = shown as? JPEGExportController {
            let exportButton = try button("Export…", in: dialog)
            #expect(dialog.encoding == nil && dialog.result != nil && exportButton.isEnabled)
        } else {
            #expect(shown is UIActivityViewController)
        }
        try await dismissExport(shown)
        await cleanUp(controller)
    }

    /// The dialog opens with the JPEG it's handed and its settings, ready to export at once.
    @Test func theDialogOpensWithTheJPEGItsHanded() async throws {
        let raster = try raster()
        let options = JPEGOptions(quality: 0.4, red: 0, green: 0, blue: 1)
        let encoded = try await ImageExporter.shared.jpeg(raster, options: options)
        var exported: Data?
        let dialog = JPEGExportController(raster: raster, encoded: (encoded, options), share: { exported = $0; return nil }, cancelled: {})
        dialog.loadViewIfNeeded()
        #expect(dialog.encoding == nil && dialog.options == options)
        dialog.export()
        #expect(exported == encoded.data)
    }

    // MARK: Export JPEG's share sheet

    /// The dialog's commands that a share sheet over it takes away: Return and Escape, and the View menu's zooms.
    private func keysAndZooms(of dialog: JPEGExportController) -> [(Selector, Any?)] {
        let keys = (dialog.keyCommands ?? []).compactMap { command in command.action.map { ($0, command as Any?) } }
        let zooms = [#selector(JPEGExportController.zoomIn(_:)), #selector(JPEGExportController.zoomOut(_:)),
                     #selector(JPEGExportController.fitCanvas(_:)), #selector(JPEGExportController.actualPixels(_:))]
        return keys + zooms.map { ($0, nil) }
    }

    /// The share sheet over the dialog, once it's up.
    private func shareSheet(over dialog: UIViewController) async throws -> UIActivityViewController {
        try await eventually { dialog.presentedViewController.map { !$0.isBeingPresented } == true }
        return try #require(dialog.presentedViewController as? UIActivityViewController)
    }

    /// Export… offers the JPEG at once in a share sheet over the dialog, from its Export… button, the project still held;
    /// while it's up, Return, Escape, Export… and the zoom commands aren't the dialog's. Once the JPEG is shared, the sheet
    /// and the dialog go together, letting the project go.
    @Test func sharingTheJPEGEndsTheExport() async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try start("Export JPEG", in: controller)
        let dialog = try #require(try await shown(over: controller) as? JPEGExportController)
        let exportButton = try button("Export…", in: dialog)
        for (action, sender) in keysAndZooms(of: dialog) { #expect(dialog.canPerformAction(action, withSender: sender), "\(action)") }

        exportButton.sendActions(for: .primaryActionTriggered)
        let share = try await shareSheet(over: dialog)
        #expect(controller.presentedViewController === dialog && tab.session.isProjectBusy)
        #expect(share.popoverPresentationController?.sourceView === exportButton)
        let file = try #require(controller.offeredFile)
        #expect(try Data(contentsOf: file) == dialog.result?.data && file.pathExtension == "jpg")
        for (action, sender) in keysAndZooms(of: dialog) { #expect(!dialog.canPerformAction(action, withSender: sender), "\(action)") }
        let written = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.systemFileNumber] as? Int
        exportButton.sendActions(for: .primaryActionTriggered)
        #expect(dialog.presentedViewController === share && controller.offeredFile == file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.systemFileNumber] as? Int == written)

        try await finish(share, completed: true)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        // Required, as a project left held would hold up closing its tab.
        try #require(!tab.session.isProjectBusy)
        await cleanUp(controller)
    }

    /// A share sheet put away with nothing shared, as by a tap off it, leaves the dialog as it was, the project held and
    /// its keys and zooms its own again; Export… then offers the JPEG as it's set by then, and Cancel ends the export.
    @Test func puttingTheShareSheetAwayReturnsToTheDialog() async throws {
        let (window, controller, tab) = try await shownWindow()
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: JPEGExportController.qualityKey)
        defer {
            window.isHidden = true
            defaults.set(saved, forKey: JPEGExportController.qualityKey)
        }
        try start("Export JPEG", in: controller)
        let dialog = try #require(try await shown(over: controller) as? JPEGExportController)
        let exportButton = try button("Export…", in: dialog)
        exportButton.sendActions(for: .primaryActionTriggered)
        try await finish(try await shareSheet(over: dialog), completed: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.presentedViewController === dialog && dialog.presentedViewController == nil && tab.session.isProjectBusy)
        for (action, sender) in keysAndZooms(of: dialog) { #expect(dialog.canPerformAction(action, withSender: sender), "\(action)") }

        dialog.chooseQuality(0.3)
        await dialog.encoding?.value
        exportButton.sendActions(for: .primaryActionTriggered)
        let again = try await shareSheet(over: dialog)
        #expect(try Data(contentsOf: try #require(controller.offeredFile)) == dialog.result?.data)
        try await finish(again, completed: false)
        try button("Cancel", in: dialog).sendActions(for: .primaryActionTriggered)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        try #require(!tab.session.isProjectBusy)
        await cleanUp(controller)
    }

    // MARK: The keyboard once an export ends

    /// Once an export ends, however it ends, the canvas has the keyboard again, as before the export, and the menu
    /// bar's commands reach the window without a tap on the canvas first: Export JPEG's dialog gone with its share
    /// sheet, once the JPEG is shared, or by its Cancel, a share sheet put away over it or not, and Export PNG's share
    /// sheet gone, shared or put away. Once a share sheet has been over the dialog, UIKit gives the keyboard back to
    /// nothing as the dialog goes, with the sheet or after it, so those cases fail unless the window asks for it back.
    /// UIKit does so too once a tap on Save Image or Copy has taken the keyboard into the sheet, which runs in another
    /// process: that's checked on the device. Here UIKit gives the canvas the keyboard back itself as Export PNG's
    /// sheet goes, so the PNG cases check too that the window asks for it back once the sheet has gone.
    @Test(arguments: ["Export JPEG shared", "Export JPEG put away, then cancelled", "Export JPEG cancelled", "Export PNG shared",
                      "Export PNG put away"])
    func theCanvasHasTheKeyboardOnceAnExportEnds(_ ending: String) async throws {
        let (window, controller, tab) = try await shownWindow()
        defer { window.isHidden = true }
        try await eventually { tab.canvas.isFirstResponder }
        try #require(tab.canvas.isFirstResponder)

        if ending.hasPrefix("Export JPEG") {
            try start("Export JPEG", in: controller)
            let dialog = try #require(try await shown(over: controller) as? JPEGExportController)
            if ending != "Export JPEG cancelled" {
                try button("Export…", in: dialog).sendActions(for: .primaryActionTriggered)
                let share = try await shareSheet(over: dialog)
                try await finish(share, completed: ending == "Export JPEG shared")
            }
            if ending != "Export JPEG shared" {
                try await eventually { dialog.isFirstResponder }
                try #require(dialog.isFirstResponder)
                try button("Cancel", in: dialog).sendActions(for: .primaryActionTriggered)
            }
        } else {
            let focusRequests = tab.session.canvasFocusRequest
            try start("Export PNG", in: controller)
            let share = try #require(try await shown(over: controller) as? UIActivityViewController)
            try await finish(share, completed: ending == "Export PNG shared")
            #expect(tab.session.canvasFocusRequest > focusRequests, "The window asks for the keyboard back")
        }
        try await eventually { controller.presentedViewController == nil && tab.canvas.isFirstResponder }
        #expect(controller.presentedViewController == nil)
        #expect(tab.canvas.isFirstResponder)
        let zoom = tab.session.viewport.zoom
        #expect(UIApplication.shared.sendAction(#selector(EditorWindowController.zoomIn(_:)), to: nil, from: nil, for: nil))
        #expect(tab.session.viewport.zoom > zoom)
        await cleanUp(controller)
    }

    // MARK: The files exports offer

    /// Whether there's a file or folder at `url`.
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Each export offers its file from a folder of its own, so one never writes over another's, as two windows' exports
    /// of projects of the same name would: a file still offered stays, and the folders of the exports that are over go as
    /// the next export writes its file, with any left from before.
    @Test func eachExportOffersItsFileFromAFolderOfItsOwn() async throws {
        let first = try await shownWindow(), second = try await shownWindow()
        defer { for window in [first.window, second.window] { window.isHidden = true } }
        let left = FileManager.default.temporaryDirectory.appending(path: "Exports/Left from before", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)

        try start("Export PNG", in: first.controller)
        let firstShare = try #require(try await shown(over: first.controller) as? UIActivityViewController)
        let firstFile = try #require(first.controller.offeredFile)
        try start("Export PNG", in: second.controller)
        let secondShare = try #require(try await shown(over: second.controller) as? UIActivityViewController)
        let secondFile = try #require(second.controller.offeredFile)
        #expect(firstFile.lastPathComponent == "Untitled.png" && secondFile.lastPathComponent == "Untitled.png")
        #expect(firstFile.deletingLastPathComponent() != secondFile.deletingLastPathComponent())
        #expect(firstFile.deletingLastPathComponent().deletingLastPathComponent() == left.deletingLastPathComponent())
        #expect(exists(firstFile) && exists(secondFile) && !exists(left))
        #expect(try Data(contentsOf: firstFile).starts(with: [0x89, 0x50, 0x4E, 0x47]))

        try await finish(firstShare, completed: true)
        try await finish(secondShare, completed: false)
        #expect(exists(firstFile) && exists(secondFile))
        try start("Export JPEG", in: first.controller)
        let dialog = try #require(try await shown(over: first.controller) as? JPEGExportController)
        try button("Export…", in: dialog).sendActions(for: .primaryActionTriggered)
        let thirdShare = try await shareSheet(over: dialog)
        let thirdFile = try #require(first.controller.offeredFile)
        #expect(exists(thirdFile) && !exists(firstFile.deletingLastPathComponent()) && !exists(secondFile.deletingLastPathComponent()))
        try await finish(thirdShare, completed: true)
        try await eventually { first.controller.presentedViewController == nil }
        await cleanUp(first.controller)
        await cleanUp(second.controller)
    }

    /// iPadOS offers Save Image in the share sheet only to an app that says why it adds to the photo library, which it
    /// asks the first time: the app says so.
    @Test func theAppSaysWhyItAddsToThePhotoLibrary() {
        let reason = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String
        #expect(reason == "Compositor saves the images you export to your photo library.")
    }
}
