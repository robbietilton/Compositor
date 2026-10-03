import PhotosUI
import Symbols
import UIKit
import UniformTypeIdentifiers

/// A window of the iPad app, laid out as the Mac's window is: a toolbar with the projects as tabs and the zoom
/// controls at its end; the tool in hand's settings under it; the tools down the left, the canvas, and the Layers
/// panel on the right; and the status line along the foot. Each tab is a document of its own, saved as it changes; a
/// window can hold several, and several windows can be open. It sits in a navigation controller for its bar, which
/// is the Mac's toolbar here.
final class EditorWindowController: UIViewController, UIDocumentPickerDelegate, PHPickerViewControllerDelegate,
                                    UIDropInteractionDelegate {
    static let restorationActivityType = "com.wonderassembly.compositor.ipad.window"
    /// Every window's controller, so a project already open in one is brought forward rather than opened twice.
    private static let controllers = NSHashTable<EditorWindowController>.weakObjects()

    private(set) var tabs: [EditorTab] = []
    private var activeID: UUID?
    var activeTab: EditorTab? { tabs.first { $0.id == activeID } }

    private let tabStrip = TabStripView()
    private lazy var newTabItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.newCanvasTab(nil) })
        item.accessibilityLabel = "New canvas"
        return item
    }()
    // While text is typed, they take back what was typed, as the Mac's Edit menu does then.
    private lazy var undoItem = barItem(symbol: "arrow.uturn.backward", label: "Undo") { [weak self] session in
        if let text = self?.textUndo { text.undo() } else { session.undo() }
    }
    private lazy var redoItem = barItem(symbol: "arrow.uturn.forward", label: "Redo") { [weak self] session in
        if let text = self?.textUndo { text.redo() } else { session.redo() }
    }
    /// Who draws, Apple Pencil alone or fingers too: a switch for the whole app rather than a tool, so it sits by Undo
    /// and Redo, not among the tools. It's there once Apple Pencil has turned up.
    private lazy var inputItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: nil, image: nil, primaryAction: UIAction { [weak self] _ in self?.switchInput() })
        item.isHidden = true
        return item
    }()
    /// Who draws, which the toolbar's switch shows and the canvas follows.
    var input = DrawingInput.shared
    /// Whether the switch last showed Apple Pencil alone, so a flip morphs one symbol into the other.
    private var shownPencilOnly: Bool?
    private lazy var typePickers: TypePickers = {
        let pickers = TypePickers()
        pickers.session = { [weak self] in self?.activeTab?.session }
        pickers.returnFocus = { [weak self] in self?.activeTab?.canvas.textEditor?.textView.becomeFirstResponder() }
        return pickers
    }()

    /// The undo of the text being typed, while there is some.
    private var textUndo: UndoManager? {
        guard activeTab?.session.textDraft != nil else { return nil }
        return activeTab?.canvas.textEditor?.textView.undoManager
    }
    private lazy var fitItem = barItem(title: "Fit", label: "Fit canvas in window") { $0.fit() }
    private lazy var actualItem = barItem(title: "100%", label: "Actual pixels") { $0.zoom(to: 1) }
    private lazy var zoomInItem = barItem(symbol: "plus.magnifyingglass", label: "Zoom in") { $0.zoomKeyboard(by: 1) }
    private lazy var zoomOutItem = barItem(symbol: "minus.magnifyingglass", label: "Zoom out") { $0.zoomKeyboard(by: -1) }
    private let optionsBar = ToolOptionsBar()
    private let rail = ToolRailView()
    private let canvasHost = UIView()
    private let newCanvas = NewCanvasView()
    private let loadingCard = LoadingView()
    /// The outline around the canvas while something dragged over the window can be dropped, as on the Mac.
    private let dropTarget = UIView()
    private let layersPanel = LayersPanelView()
    private let statusBar = StatusBarView()

    private enum Picking { case project, images }
    private var picking: Picking?
    /// The adjustment layer whose editor is getting the pixels beneath it.
    private var startingAdjustment: UUID?

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.controllers.add(self)
        view.backgroundColor = UIColor(white: 0.14, alpha: 1)

        // The Mac's toolbar, group for group: New Canvas; the tabs, with no background of their own; and at the end
        // Fit, 100%, and zooming in and out, each group sharing a glass background. Undo and Redo lead the trailing
        // groups, for a window that may have no keyboard or menu bar in reach.
        navigationItem.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [newTabItem], representativeItem: nil)]
        navigationItem.titleView = tabStrip
        navigationItem.trailingItemGroups = [[inputItem], [undoItem, redoItem], [fitItem], [actualItem], [zoomInItem, zoomOutItem]]
            .map { UIBarButtonItemGroup(barButtonItems: $0, representativeItem: nil) }

        tabStrip.onSelect = { [weak self] in self?.select($0) }
        tabStrip.onClose = { [weak self] in self?.close($0) }
        tabStrip.menu = { [weak self] in self?.tabMenu($0) }

        rail.presenter = self
        optionsBar.onChooseForeground = { [weak self] in self?.rail.chooseColor(background: false, from: $0) }
        optionsBar.onChooseFont = { [weak self] source in
            guard let self else { return }
            self.typePickers.chooseFont(from: source, presenter: self)
        }
        optionsBar.onChooseTextColor = { [weak self] source in
            guard let self else { return }
            self.typePickers.chooseTextColor(from: source, presenter: self)
        }
        layersPanel.presenter = self

        newCanvas.onCreate = { [weak self] in self?.createCanvas(width: $0, height: $1) }
        newCanvas.onOpen = { [weak self] in self?.openProject(nil) }
        newCanvas.onImportPhotos = { [weak self] in self?.importPhotos(nil) }
        newCanvas.onImportFiles = { [weak self] in self?.importImages(nil) }
        newCanvas.onOpenRecent = { [weak self] in self?.open([$0]) }

        dropTarget.isUserInteractionEnabled = false
        dropTarget.isHidden = true
        dropTarget.layer.borderWidth = 3
        dropTarget.layer.cornerRadius = 8
        dropTarget.layer.borderColor = view.tintColor.cgColor
        view.addInteraction(UIDropInteraction(delegate: self))

        let optionsLine = Self.separator(vertical: false)
        let railLine = Self.separator(vertical: true), panelLine = Self.separator(vertical: true)
        let statusLine = Self.separator(vertical: false)
        for subview in [optionsBar, optionsLine, rail, railLine, canvasHost, newCanvas, loadingCard, dropTarget, panelLine,
                        layersPanel, statusLine, statusBar] as [UIView] {
            view.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        // Under the bar, which keeps clear of the window controls iPadOS puts at the window's leading top corner.
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: safe.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            optionsLine.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            // The tools, the canvas and the Layers panel side by side, between the settings and the status line.
            rail.topAnchor.constraint(equalTo: optionsLine.bottomAnchor), rail.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            rail.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            railLine.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            railLine.topAnchor.constraint(equalTo: rail.topAnchor), railLine.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            canvasHost.leadingAnchor.constraint(equalTo: railLine.trailingAnchor),
            canvasHost.trailingAnchor.constraint(equalTo: panelLine.leadingAnchor),
            canvasHost.topAnchor.constraint(equalTo: rail.topAnchor), canvasHost.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            newCanvas.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor), newCanvas.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            newCanvas.topAnchor.constraint(equalTo: canvasHost.topAnchor), newCanvas.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            loadingCard.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor), loadingCard.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            loadingCard.topAnchor.constraint(equalTo: canvasHost.topAnchor), loadingCard.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            dropTarget.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor), dropTarget.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            dropTarget.topAnchor.constraint(equalTo: canvasHost.topAnchor), dropTarget.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            panelLine.topAnchor.constraint(equalTo: rail.topAnchor), panelLine.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            layersPanel.leadingAnchor.constraint(equalTo: panelLine.trailingAnchor),
            layersPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            layersPanel.topAnchor.constraint(equalTo: rail.topAnchor), layersPanel.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            statusLine.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ] + [optionsLine, statusLine].flatMap { line in
            [line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
        })
        if tabs.isEmpty { addTab() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    /// Undo and Redo in the menu bar, on the keyboard and in the system's gestures go to the tab in front.
    override var undoManager: UndoManager? { activeTab?.undoManager }

    /// Follows the tab in front: UIKit calls this again whenever anything it read from that tab's editor changes.
    override func updateProperties() {
        super.updateProperties()
        showInputSwitch()
        guard let tab = activeTab else { return }
        let session = tab.session
        tabStrip.show(tabs.map { .init(id: $0.id, title: $0.title, modified: $0.document != nil && $0.session.isModified) },
                      active: activeID)
        // Typing changes the draft, which brings this round again.
        _ = session.textDraft
        undoItem.isEnabled = textUndo?.canUndo ?? session.canUndo
        redoItem.isEnabled = textUndo?.canRedo ?? session.canRedo
        let hasDocument = session.document != nil
        for item in [fitItem, actualItem, zoomInItem, zoomOutItem] { item.isEnabled = hasDocument }
        tab.canvas.consumeFocusRequest(session.canvasFocusRequest, hasDocument: hasDocument)
        newCanvas.isHidden = !tab.isEmpty
        // The opening tab's Loading card, in the same pass that hides New canvas.
        loadingCard.progress = tab.loading
        loadingCard.updatePropertiesIfNeeded()
        view.window?.windowScene?.title = tab.title
        rail.session = session
        optionsBar.session = session
        layersPanel.session = session
        statusBar.session = session
        // An opening tab isn't empty, though it has nothing yet; its canvas's handles and outlines wait for its picture.
        let opening = tab.loading?.isShowing == true
        layersPanel.isOpening = opening
        statusBar.isOpening = opening
        tab.canvas.overlayView.isHidden = opening
        // Who draws, which Apple Pencil turning up and the toolbar's switch change.
        statusBar.fingerPaints = input.fingerPaints
        tab.canvas.fingerPaints = input.fingerPaints
        // What the editor asks of whoever shows it: a Photoshop file's conversion report, a RAW file's development,
        // and the errors it runs into. Shown once the update is over.
        if session.showsConversionSheet || session.showsRawDevelop || session.importError != nil || session.brushError != nil
            || session.cropError != nil || session.saveError != nil || session.changedOnDisk || session.selectionAmountOperation != nil {
            DispatchQueue.main.async { [weak self] in self?.presentEditorRequests(for: tab) }
        }
        if session.adjustmentEditingID != nil || session.levels != nil || session.hueSaturation != nil || session.filterEdit != nil
            || session.effectsEditing != nil || presentedViewController is AdjustmentEditorController {
            DispatchQueue.main.async { [weak self] in self?.followAdjustmentEditing(for: tab) }
        }
    }

    /// Opens the editor for the edit the editor has open, as the Mac's floating panels open, beside the Layers panel with
    /// the canvas still free to move and zoom; and closes it when the edit ends. An adjustment layer chosen for editing
    /// first gets the pixels beneath it, as on the Mac.
    private func followAdjustmentEditing(for tab: EditorTab) {
        guard tab.id == activeID else { return }
        let session = tab.session
        // An effect undone, or gone with its layer, takes its editing with it.
        session.endEffectsEditingIfGone()
        // Another edit's editor takes the place of an effect's panel, the effect kept as its OK keeps it: the iPad shows
        // one at a time, where the Mac's panels stay side by side.
        if session.effectsEditing != nil,
           session.adjustmentEditingID != nil || session.levels != nil || session.hueSaturation != nil || session.filterEdit != nil {
            session.finishEffectsEditing(commit: true)
        }
        let shown = presentedViewController as? AdjustmentEditorController
        if let shown, !shown.isOpen {
            guard !shown.isBeingDismissed else { return }
            // With whatever is over it, as its color picker; then the next editor, as one effect's follows another's.
            dismiss(animated: true) { [weak self] in self?.followAdjustmentEditing(for: tab) }
            return
        }
        if let id = session.adjustmentEditingID, session.adjustmentOriginal == nil, session.levels == nil,
           session.hueSaturation == nil, session.filterEdit == nil {
            guard startingAdjustment != id else { return }
            // Only kinds the iPad has an editor for: any other would hold the project with nothing to close it.
            guard let kind = session.document?.layers.first(where: { $0.id == id })?.adjustment?.kind,
                  AdjustmentEditors.kinds.contains(kind) else {
                session.adjustmentEditingID = nil
                return
            }
            startingAdjustment = id
            Task {
                await session.beginAdjustmentEditing(id)
                startingAdjustment = nil
                setNeedsUpdateProperties()
            }
            return
        }
        guard shown == nil, presentedViewController == nil, let editor = AdjustmentEditors.editor(for: session) else { return }
        editor.modalPresentationStyle = .popover
        if let popover = editor.popoverPresentationController {
            popover.sourceView = layersPanel
            popover.sourceRect = CGRect(x: 0, y: 140, width: 1, height: 1)
            popover.permittedArrowDirections = .right
            // Beside an effect's panel the Layers panel, the tools and their options stay free too, as beside the Mac's;
            // not the tabs or the toolbar, which would leave it over another tab.
            popover.passthroughViews = editor is EffectEditorController ? [canvasHost, layersPanel, rail, optionsBar] : [canvasHost]
        }
        present(editor, animated: true)
    }

    private func presentEditorRequests(for tab: EditorTab) {
        guard tab.id == activeID else { return }
        let session = tab.session
        guard isClear else {
            // A failed save or a change made elsewhere comes whenever it comes: it waits for what's over the window to
            // go, checked twice a second; so does anything else beside an effect's panel, for what's over the panel.
            if session.saveError != nil || (session.changedOnDisk && presentedViewController !== changeQuestion)
                || presentedViewController is EffectEditorController, !rechecksRequests {
                rechecksRequests = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.rechecksRequests = false
                    self?.setNeedsUpdateProperties()
                }
            }
            return
        }
        if session.showsConversionSheet {
            presentSheet(PSDConversionController(session: session))
        } else if session.showsRawDevelop, let develop = session.rawDevelop {
            presentSheet(RawDevelopController(session: session, url: develop.url, settings: develop.settings))
        } else if let message = session.importError {
            session.importError = nil
            showMessage("Import couldn’t finish", message, overWhatsShown: false)
        } else if let message = session.brushError {
            session.brushError = nil
            showMessage("Couldn’t paint", message, overWhatsShown: false)
        } else if let message = session.cropError {
            session.cropError = nil
            showMessage("Couldn’t crop", message, overWhatsShown: false)
        } else if let message = session.saveError {
            session.saveError = nil
            showMessage("Couldn’t save the project", message, overWhatsShown: false)
        } else if session.changedOnDisk, let document = tab.document {
            askAboutChange(to: tab, document: document)
        } else if let operation = session.selectionAmountOperation {
            askSelectionAmount(operation, for: session)
        }
    }

    /// Something else changed the project's file while it has unsaved work: the Mac's question, whether to take that
    /// version up. Return reverts, as the Mac's default button does, and Escape keeps what the editor has.
    private func askAboutChange(to tab: EditorTab, document: CompositorDocument) {
        let alert = UIAlertController(title: "“\(tab.url?.lastPathComponent ?? "Untitled")” was changed on disk.",
                                      message: "Another app changed this project. You can revert to the version on disk, losing your unsaved changes, or keep what you have.",
                                      preferredStyle: .alert)
        let revert = UIAlertAction(title: "Revert", style: .destructive) { _ in document.answerChangeOnDisk(revert: true) }
        alert.addAction(revert)
        alert.addAction(UIAlertAction(title: "Keep Mine", style: .cancel) { _ in document.answerChangeOnDisk(revert: false) })
        alert.preferredAction = revert
        changeQuestion = alert
        present(alert, animated: true)
    }

    /// The question a change made elsewhere asks, while it's shown.
    private weak var changeQuestion: UIAlertController?

    /// Nothing over the window, or only an effect's panel, which leaves the window free as the Mac's does and gives way
    /// to whatever the window shows next; not while the panel shows something itself, its color picker, or is going.
    private var isClear: Bool {
        guard let presented = presentedViewController else { return true }
        return presented is EffectEditorController && presented.presentedViewController == nil && !presented.isBeingDismissed
    }

    /// An effect's panel gives way to anything else the window shows, its effect kept as its OK keeps it: the iPad shows
    /// one at a time, where the Mac's panel stays beside a dialog or another panel.
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        guard let panel = presentedViewController as? EffectEditorController, controller !== panel else {
            super.present(controller, animated: animated, completion: completion)
            return
        }
        panel.session.finishEffectsEditing(commit: true)
        dismiss(animated: false) { super.present(controller, animated: animated, completion: completion) }
    }
    /// A check for what the editor asks is due, once what's over the window may have gone.
    private var rechecksRequests = false

    /// Expand, Contract or Feather from the Select menu asks by how many pixels, as the Mac's sheet does.
    private func askSelectionAmount(_ operation: EditorSession.SelectionAmountOperation, for session: EditorSession) {
        let (title, amount, maximum) = switch operation {
        case .expand: ("Expand Selection", session.selectionExpandAmount, 500)
        case .contract: ("Contract Selection", session.selectionContractAmount, 500)
        case .feather: ("Feather Selection", session.selectionFeatherAmount, 250)
        }
        let alert = UIAlertController(title: title, message: "A whole number from 1 to \(maximum) px.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = String(amount)
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in session.selectionAmountOperation = nil })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            if let value = Int(text), (1...maximum).contains(value) { session.confirmSelectionAmount(value) }
            else { session.selectionAmountOperation = nil }
        })
        present(alert, animated: true)
    }

    // MARK: Tabs

    @discardableResult private func addTab() -> EditorTab {
        let tab = EditorTab()
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // An effect's panel is bound to its tab's layer: it goes with that tab, OK'd, as when anything else takes its
        // place; a tab closing cancels its own as it settles.
        if let panel = presentedViewController as? EffectEditorController, panel.session !== tab.session,
           tabs.contains(where: { $0.session === panel.session }), !panel.isBeingDismissed {
            panel.session.finishEffectsEditing(commit: true)
            dismiss(animated: true)
        }
        // Keys held go with the canvas that had them: one let up after the switch never reaches this window.
        releaseKeys()
        activeID = id
        canvasHost.subviews.forEach { $0.removeFromSuperview() }
        let canvas = tab.canvas
        canvas.fingerPaints = input.fingerPaints
        canvas.pencilSeen = { [weak self] in self?.pencilTurnedUp() }
        canvas.keysSeen = { [weak self] in self?.holdKeys($0) }
        // Space lends the Hand, which the rail shows in hand while it's held.
        canvas.spaceChanged = { [weak self] held in self?.rail.heldTool = held ? .hand : nil }
        canvasHost.addSubview(canvas)
        canvas.frame = canvasHost.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        newCanvas.showRecent(PadRecentProjects.shared.urls)
        setNeedsUpdateProperties()
        becomeFirstResponder()
    }

    /// Saves and closes the tab's project, keeping what's in progress as the Mac's Quit does. A project that can't be
    /// saved keeps its tab, which says why, as the Mac's close does when its Save fails. The last tab is replaced by an
    /// empty one, as on the Mac.
    func close(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), !closing.contains(id) else { return }
        // A change made elsewhere is asked about first, as the Mac's question keeps its window open.
        if tab.session.changedOnDisk {
            select(id)
            return
        }
        // Text that can't be drawn keeps the tab, as it keeps the Mac from quitting.
        guard tab.session.finishText() else { return }
        // Its dialog, which holds the project, ends as its Cancel would.
        if dialogSession === tab.session { cancelDialog() }
        // Before its canvas goes, which takes back a stroke still being drawn.
        tab.session.finishBrushImmediately()
        // Its editor goes with it; closing cancels the edit.
        if let editor = presentedViewController as? AdjustmentEditorController, editor.session === tab.session {
            dismiss(animated: true)
        }
        guard let document = tab.document else {
            remove(tab)
            return
        }
        closing.insert(id)
        Task {
            defer { closing.remove(id) }
            await tab.settle()
            // A change made elsewhere is settled first, in front, where its question shows: taken up, there may be
            // nothing left to save.
            if document.changeWaits, tabs.contains(where: { $0 === tab }) { select(id) }
            await document.settleChange()
            if tab.session.isModified || document.hasUnsavedChanges {
                do { try await document.saveNow() } catch {
                    guard tabs.contains(where: { $0 === tab }) else { return }
                    select(id)
                    askToClose(tab, unsaved: error)
                    return
                }
            }
            remove(tab)
        }
    }

    /// Tabs saving as they close.
    private var closing: Set<UUID> = []

    /// Takes the tab out of the window and closes its file.
    private func remove(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        Task { await tab.close() }
        if tabs.isEmpty { addTab() }
        else if activeID == tab.id { select(tabs[min(index, tabs.count - 1)].id) }
        else { setNeedsUpdateProperties() }
    }

    /// A tab's project couldn't be saved as it closed. It stays, unless what isn't saved is let go, as the Mac's close
    /// asks.
    private func askToClose(_ tab: EditorTab, unsaved error: any Error) {
        let alert = UIAlertController(title: "Couldn’t save the project",
                                      message: error.localizedDescription + " Your changes will be lost if you don’t save them.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don’t Save", style: .destructive) { [weak self] _ in self?.closeWithoutSaving(tab.id) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        (presentedViewController ?? self).present(alert, animated: true)
    }

    /// Closes the tab, letting go of what its project hasn't saved: Don't Save, once a save has failed as it closed.
    func closeWithoutSaving(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.document?.stopSaving()
        remove(tab)
    }

    private func tabMenu(_ id: UUID) -> UIMenu? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let fileActions: [UIMenuElement] = tab.document == nil ? [] : [
            UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.select(id); self?.renameProject(nil) },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.select(id); self?.duplicateProject(nil) },
            UIAction(title: "Export PNG…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.select(id); self?.exportPNG(nil) },
            UIAction(title: "Export JPEG…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.select(id); self?.exportJPEG(nil) },
        ]
        let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.close(id) }
        return UIMenu(children: [UIMenu(options: .displayInline, children: fileActions), close])
    }

    /// Apple Pencil turned up on this window's canvas. The first time since launch it takes drawing from fingers, unless
    /// the switch was left with fingers drawing too, and the status line says so.
    private func pencilTurnedUp() {
        if input.pencilTurnedUp() { inputSwitched(pencilOnly: true) }
    }

    /// Flips who draws, from the toolbar's switch.
    func switchInput() {
        input.pencilOnly.toggle()
        inputSwitched(pencilOnly: input.pencilOnly)
    }

    /// Says who draws now, as it just changed.
    private func inputSwitched(pencilOnly: Bool) {
        statusBar.flash(DrawingInput.description(pencilOnly: pencilOnly))
    }

    /// The switch for who draws: there once Apple Pencil has turned up, coming in as it does, and showing who draws
    /// now, one symbol morphing into the other as it's flipped.
    private func showInputSwitch() {
        let pencilOnly = input.pencilOnly
        inputItem.accessibilityLabel = DrawingInput.description(pencilOnly: pencilOnly)
        if let image = UIImage(systemName: DrawingInput.symbol(pencilOnly: pencilOnly)) {
            if shownPencilOnly == nil || inputItem.isHidden { inputItem.image = image }
            else if shownPencilOnly != pencilOnly { inputItem.setSymbolImage(image, contentTransition: .replace) }
        }
        shownPencilOnly = pencilOnly
        guard inputItem.isHidden == input.hasPencil else { return }
        if input.hasPencil, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.35) {
                self.inputItem.isHidden = false
                self.navigationController?.navigationBar.layoutIfNeeded()
            }
        } else {
            inputItem.isHidden = !input.hasPencil
        }
    }

    // MARK: Opening

    /// Opens projects in tabs of their own (bringing forward one that's already open) and brings images into the
    /// project in front, as a drop on the Mac's window does.
    func open(_ urls: [URL]) {
        let projects = urls.filter { Self.isProject($0) }
        let images = urls.filter { !Self.isProject($0) }
        for url in projects { open(project: url) }
        if !images.isEmpty { Task { await bringIn(images) } }
    }

    private func open(project url: URL) {
        for controller in Self.controllers.allObjects {
            guard let tab = controller.tabs.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) else { continue }
            controller.select(tab.id)
            if controller !== self, let scene = controller.view.window?.windowScene {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
            }
            return
        }
        // An empty tab in front takes the project; otherwise it gets a tab of its own.
        let tab = activeTab.flatMap { $0.isEmpty ? $0 : nil } ?? addTab()
        let opening = tab.open(url) { [weak self] error in
            // Closed while it opened, it says nothing.
            guard let self, tabs.contains(where: { $0 === tab }) else { return }
            // The tab opened for it goes again, unless it's the window's last.
            if tab.isEmpty, tabs.count > 1 { close(tab.id) }
            showError("Couldn’t open “\(url.deletingPathExtension().lastPathComponent)”", error)
            setNeedsUpdateProperties()
        }
        setNeedsUpdateProperties()
        Task {
            if (try? await opening.value) != nil { PadRecentProjects.shared.note(url) }
            setNeedsUpdateProperties()
        }
    }

    /// Images into the project in front, centered on `point` (in document pixels) or on the canvas; into an empty tab,
    /// the first one sets the canvas and the project gets a file.
    private func bringIn(_ images: [URL], into target: EditorTab? = nil, at point: CGPoint? = nil) async {
        guard !images.isEmpty, let tab = target ?? activeTab ?? tabs.first else { return }
        let importing = Timing.begin("Import images")
        tab.incoming += 1
        await tab.session.importImages(images, at: point)
        tab.incoming -= 1
        Timing.end(importing, Timing.counted(images.count, "image"))
        do { try await tab.createDocument(named: images.first?.deletingPathExtension().lastPathComponent ?? "Untitled") }
        catch { showError("Couldn’t save the new project", error) }
        setNeedsUpdateProperties()
    }

    /// Images dropped on the window or picked in Photos, into the project in front: centered where they land when
    /// dropped on the canvas (`canvasPoint`, in the canvas's coordinates), as on the Mac, or else on the canvas's middle.
    func receive(_ providers: [NSItemProvider], at canvasPoint: CGPoint? = nil) async {
        guard let tab = activeTab else { return }
        // On their way in from the moment they're handed over, which can take a while from iCloud.
        tab.incoming += 1
        defer { tab.incoming -= 1 }
        let session = tab.session
        let point = canvasPoint.flatMap { point in
            session.document.map { session.viewport.documentPoint(from: point, documentSize: $0.size) }
        }
        // Copies are named as Photos and other apps name the images, rather than after the files handed over.
        let (urls, unreadable) = await ItemProviderFiles.urls(from: providers, suggestedNames: true)
        await bringIn(urls, into: tab, at: point)
        if unreadable {
            let message = "Some items couldn’t be read. Bring in JPEG, PNG, HEIC, TIFF, or Photoshop (PSD) images from Photos or Files."
            session.importError = [session.importError, message].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    /// A project dragged in from Files opens where it is, as it does from Files' Open; one that can only be copied
    /// comes in as a copy among the app's own projects.
    private func openDropped(_ provider: NSItemProvider) {
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.compositorProject.identifier) { [weak self] url, inPlace, _ in
            guard let url else { return }
            // A copy lasts only until this returns, so it's kept first.
            let kept = inPlace ? url : CompositorDocument.unusedURL(named: url.deletingPathExtension().lastPathComponent)
            if !inPlace {
                do { try FileManager.default.copyItem(at: url, to: kept) } catch { return }
            }
            Task { @MainActor [weak self] in self?.open(project: kept) }
        }
    }

    private func createCanvas(width: Int, height: Int) {
        guard let tab = activeTab else { return }
        tab.session.createNewProject(width: width, height: height)
        Task {
            do { try await tab.createDocument(named: "Untitled") }
            catch { showError("Couldn’t save the new project", error) }
            setNeedsUpdateProperties()
        }
    }

    private static func isProject(_ url: URL) -> Bool {
        // A project is a package, a folder, so its type is looked up among packages rather than files.
        UTType(filenameExtension: url.pathExtension, conformingTo: .package)?.conforms(to: .compositorProject) == true
    }

    private func pick(_ kind: Picking) {
        picking = kind
        // Images are copied in, as the importer reads them once; projects are opened where they are.
        let picker = kind == .project
            ? UIDocumentPickerViewController(forOpeningContentTypes: [.compositorProject], asCopy: false)
            : UIDocumentPickerViewController(forOpeningContentTypes: UTType.importableImages.filter { $0 != .svg }, asCopy: true)
        picker.allowsMultipleSelection = kind == .images
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch picking {
        case .project: urls.first.map { open(project: $0) }
        case .images: Task { await bringIn(urls) }
        case nil: break
        }
        picking = nil
    }

    /// Photos runs the picker in its own process, so the app needs no access to the library; it gets the photos picked,
    /// as they are, HEIC and RAW included.
    @objc func importPhotos(_ sender: Any?) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task { await receive(results.map(\.itemProvider)) }
    }

    // MARK: Drag and drop

    /// Images and projects dropped on the window, as on the Mac: images into the project in front, centered where they
    /// land on the canvas; projects in tabs of their own.
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.compositorProject.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        dropTarget.isHidden = !acceptsDrop
        return UIDropProposal(operation: acceptsDrop ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) { dropTarget.isHidden = true }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) { dropTarget.isHidden = true }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        dropTarget.isHidden = true
        let providers = session.items.map(\.itemProvider)
        let projects = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.compositorProject.identifier) }
        projects.forEach(openDropped)
        let images = providers.filter { !projects.contains($0) }
        let location = session.location(in: canvasHost)
        guard !images.isEmpty else { return }
        Task { await receive(images, at: canvasHost.bounds.contains(location) ? location : nil) }
    }

    /// Not while the project is busy or a dialog is up, as on the Mac.
    private var acceptsDrop: Bool {
        guard let session = activeTab?.session, isClear else { return false }
        return session.levels == nil && !session.isProjectBusy && !session.showsNewDocument && !session.showsImporter
            && session.renamingLayerID == nil
    }

    // MARK: Commands (the menu bar, the keyboard and the buttons)

    @objc func newCanvasTab(_ sender: Any?) {
        if let empty = tabs.first(where: \.isEmpty) { select(empty.id) } else { addTab() }
    }
    @objc func openProject(_ sender: Any?) { pick(.project) }
    @objc func importImages(_ sender: Any?) { pick(.images) }
    /// File › Open Recent › Clear Menu, as on the Mac.
    @objc func clearRecentProjects(_ sender: Any?) {
        PadRecentProjects.shared.clear()
        newCanvas.showRecent(PadRecentProjects.shared.urls)
    }
    @objc func openRecentProject(_ sender: UICommand) {
        if let reference = sender.propertyList as? Data, let url = PadRecentProjects.resolve(reference) { open([url]) }
    }

    /// Saves now, though the project saves itself as it changes; ⌘S is a habit worth keeping. Each failure says why, as
    /// on the Mac.
    @objc func saveProject(_ sender: Any?) {
        guard let tab = activeTab, let document = tab.document, beginSave(on: tab.session) else { return }
        saving = Task {
            do { try await document.saveNow() }
            catch { tab.session.saveError = error.localizedDescription }
        }
    }

    @objc func duplicateProject(_ sender: Any?) {
        guard let tab = activeTab, let document = tab.document, beginSave(on: tab.session) else { return }
        Task {
            do { open(project: try await document.duplicate()) }
            catch { showError("Couldn’t duplicate the project", error) }
        }
    }

    @objc func renameProject(_ sender: Any?) {
        guard let tab = activeTab, let document = tab.document else { return }
        let alert = UIAlertController(title: "Rename", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = tab.title
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != tab.title else { return }
            Task {
                do { try await document.rename(to: name) }
                catch { self?.showError("Couldn’t rename the project", error) }
                self?.setNeedsUpdateProperties()
            }
        })
        present(alert, animated: true)
    }

    /// Readies the project for something that works on all of it, as the Mac's project operations begin: a crop in
    /// progress is set aside and a transform kept. Not while an editor or a dialog is open over the window, which what
    /// the operation shows would have to wait for.
    private func beginProjectOperation(on session: EditorSession) -> Bool {
        guard isClear, session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        return true
    }

    /// Readies the project for a save, as the Mac's Save begins: not while text is being typed, a stroke drawn or an
    /// adjustment layer edited, which the Mac's Save waits for; a crop in progress is set aside and a transform kept.
    private func beginSave(on session: EditorSession) -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        return true
    }

    /// The project as an export takes it.
    private func exportSnapshot(of session: EditorSession) -> ProjectSnapshot? {
        beginProjectOperation(on: session) ? session.projectSnapshot() : nil
    }

    /// The resize a size dialog set going, if any. Tests wait for it.
    private(set) var resizing: Task<Void, Never>?

    /// Image › Canvas Size…, as the Mac's sheet. The project waits while it's open; OK resizes the canvas as one step to
    /// undo.
    @objc func canvasSize(_ sender: Any?) {
        if let dialog = canvasSizeDialog() { present(dialog, animated: true) }
    }
    func canvasSizeDialog() -> CanvasSizeController? {
        guard let session = activeTab?.session, let document = session.document, beginProjectOperation(on: session) else { return nil }
        session.isProjectBusy = true
        dialogSession = session
        return CanvasSizeController(document: document, session: session) { [weak self] options in
            self?.dismiss(animated: true)
            guard let options, let snapshot = session.projectSnapshot() else {
                session.isProjectBusy = false
                return
            }
            self?.resizing = Task { [weak self] in
                defer { session.isProjectBusy = false }
                do { session.applyDocumentSize(try await CanvasResizer.shared.resize(snapshot, to: options), actionName: "Canvas Size") }
                catch { self?.showError("Couldn’t change canvas size", error) }
            }
        }
    }

    /// Image › Image Size…, as the Mac's sheet. The project waits while it's open; Resize resamples the layers, or sets
    /// only the resolution, as one step to undo.
    @objc func imageSize(_ sender: Any?) {
        if let dialog = imageSizeDialog() { present(dialog, animated: true) }
    }
    func imageSizeDialog() -> ImageSizeController? {
        guard let session = activeTab?.session, let document = session.document, beginProjectOperation(on: session) else { return nil }
        session.isProjectBusy = true
        dialogSession = session
        return ImageSizeController(document: document) { [weak self] options in
            self?.dismiss(animated: true)
            guard let options, let snapshot = session.projectSnapshot() else {
                session.isProjectBusy = false
                return
            }
            self?.resizing = Task { [weak self] in
                defer { session.isProjectBusy = false }
                do { session.applyImageSize(try await ImageResizer.shared.resize(snapshot, to: options)) }
                catch { self?.showError("Couldn’t resize the image", error) }
            }
        }
    }

    /// The flattened image as PNG, to share, save to Photos or keep in Files.
    @objc func exportPNG(_ sender: Any?) {
        guard let tab = activeTab, let snapshot = exportSnapshot(of: tab.session) else { return }
        let name = tab.title
        Task {
            do {
                let data = try await ImageExporter.shared.pngData(snapshot)
                try share(data, named: name + ".png")
            } catch { showError("Couldn’t export the image", error) }
        }
    }

    /// The flattened image as JPEG, through the Mac's Export JPEG dialog: a quality and a color for transparent areas,
    /// previewed as encoded. Then, as Export PNG does, to share, save to Photos or keep in Files.
    @objc func exportJPEG(_ sender: Any?) {
        guard let tab = activeTab, let snapshot = exportSnapshot(of: tab.session) else { return }
        let session = tab.session, name = tab.title
        // The project waits while the dialog is open, as on the Mac.
        session.isProjectBusy = true
        Task { [weak self] in
            do {
                let raster = try await ImageExporter.shared.render(snapshot)
                // Another export's share sheet may have opened meanwhile, or the tab closed.
                guard let self, self.isClear, self.tabs.contains(where: { $0 === tab }),
                      !self.closing.contains(tab.id), !tab.isClosed else {
                    session.isProjectBusy = false
                    return
                }
                self.dialogSession = session
                let dialog = JPEGExportController(raster: raster) { [weak self] data in
                    session.isProjectBusy = false
                    self?.dismiss(animated: true) {
                        guard let self, let data else { return }
                        do { try self.share(data, named: name + ".jpg") }
                        catch { self.showError("Couldn’t export JPEG", error) }
                    }
                }
                let presenting = Timing.begin("JPEG dialog")
                self.present(dialog, animated: true) { Timing.end(presenting) }
            } catch {
                session.isProjectBusy = false
                self?.showError("Couldn’t export JPEG", error)
            }
        }
    }

    /// Offers `data` as a file named `name`, to share, save to Photos or keep in Files.
    private func share(_ data: Data, named name: String) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try Timing.measure("Write export", Timing.bytes(data.count)) { try data.write(to: url, options: .atomic) }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = tabStrip
        share.popoverPresentationController?.sourceRect = tabStrip.bounds
        let presenting = Timing.begin("Share sheet")
        present(share, animated: true) { Timing.end(presenting) }
    }

    @objc func closeTab(_ sender: Any?) { if let id = activeID { close(id) } }
    @objc func fitCanvas(_ sender: Any?) { activeTab?.session.fit() }
    @objc func actualPixels(_ sender: Any?) { activeTab?.session.zoom(to: 1) }
    @objc func zoomIn(_ sender: Any?) { activeTab?.session.zoomKeyboard(by: 1) }
    @objc func zoomOut(_ sender: Any?) { activeTab?.session.zoomKeyboard(by: -1) }

    /// A switch in the View menu: which of the window's settings it turns on and off.
    enum ViewSwitch: String {
        case pixelGrid, snapping, transformControls, grid, guides, rulers, snap, snapToGuides, snapToGrid, snapToLayers,
             snapToDocumentBounds, lockGuides

        var setting: ReferenceWritableKeyPath<EditorSession, Bool> {
            switch self {
            case .pixelGrid: \.showsPixelGrid
            case .snapping: \.snappingEnabled
            case .transformControls: \.showsTransformControls
            case .grid: \.showsGrid
            case .guides: \.showsGuides
            case .rulers: \.showsRulers
            case .snap: \.snapEnabled
            case .snapToGuides: \.snapToGuides
            case .snapToGrid: \.snapToGrid
            case .snapToLayers: \.snapToLayers
            case .snapToDocumentBounds: \.snapToDocumentBounds
            case .lockGuides: \.locksGuides
            }
        }
        /// Whether the iPad does what it says yet: it doesn't draw the pixel grid or rulers, and guides can't be
        /// dragged, which locking them stops.
        var isAvailable: Bool { ![.pixelGrid, .rulers, .lockGuides].contains(self) }
    }
    /// Turns the View menu's switch on or off, as named by the command.
    @objc func toggleView(_ sender: UICommand) {
        guard let session = activeTab?.session, let name = sender.propertyList as? String,
              let viewSwitch = ViewSwitch(rawValue: name), viewSwitch.isAvailable else { return }
        session[keyPath: viewSwitch.setting].toggle()
    }
    @objc func clearGuides(_ sender: Any?) { activeTab?.session.clearGuides() }

    // Cut, Copy and Paste reach here from the menu bar and the keyboard when no text field is being edited, as the
    // Mac's do when the canvas has focus.
    @objc override func cut(_ sender: Any?) {
        guard let session = activeTab?.session, session.selection != nil, session.canCopyPixels else { Platform.beep(); return }
        Task { await session.cutSelection() }
    }
    @objc override func copy(_ sender: Any?) {
        guard let session = activeTab?.session, session.canCopyPixels || session.canCopyLayer else { Platform.beep(); return }
        session.copySelection()
    }
    @objc func copyMerged(_ sender: Any?) { activeTab?.session.copyMergedSelection() }
    /// ⌘T: the selection's pixels when there's a selection, or else the layer, in an edit that waits for Apply.
    @objc func transformLayer(_ sender: Any?) { activeTab?.session.transformCommand() }
    /// ⌘J: the selection's pixels as a new layer, or with no selection a copy of the layer.
    @objc func layerViaCopy(_ sender: Any?) { activeTab?.session.layerViaCopy() }

    // Arranging layers, as the Mac's Layer menu does.
    @objc func toggleClippingMask(_ sender: Any?) {
        guard let session = activeTab?.session, let id = session.activeLayerID else { return }
        session.toggleClippingMask(id)
    }
    @objc func groupLayers(_ sender: Any?) { activeTab?.session.groupSelectedLayers() }
    @objc func ungroupLayers(_ sender: Any?) { activeTab?.session.ungroupLayers() }
    @objc func moveOutOfFolder(_ sender: Any?) { activeTab?.session.moveActiveLayerOutOfGroup() }
    @objc func newBlankLayer(_ sender: Any?) { activeTab?.session.addBlankLayer() }
    /// Asks for the layer's new name as the Layers panel's Rename… does, where the Mac opens the name in its panel for
    /// typing.
    @objc func renameLayer(_ sender: Any?) {
        if let id = activeTab?.session.activeLayerID { layersPanel.rename(id) }
    }
    @objc func toggleLayerVisibility(_ sender: Any?) {
        guard let session = activeTab?.session, let id = session.activeLayerID else { return }
        session.toggleLayerVisibility(id)
    }
    /// ⌘] and ⌘[: the layer up or down among those beside it, by the command's offset.
    @objc func moveLayer(_ sender: UICommand) {
        guard let offset = sender.propertyList as? Int else { return }
        activeTab?.session.moveActiveLayer(by: offset)
    }
    @objc func mergeLayers(_ sender: Any?) { activeTab?.session.mergeLayers() }
    /// Flip Layer Horizontal or Vertical, by the command's direction.
    @objc func flipLayers(_ sender: UICommand) {
        guard let horizontally = sender.propertyList as? Bool else { return }
        activeTab?.session.flipLayers(horizontally: horizontally)
    }
    /// Image › Flip Canvas Horizontal or Vertical, by the command's direction.
    @objc func flipCanvas(_ sender: UICommand) {
        guard let horizontally = sender.propertyList as? Bool else { return }
        activeTab?.session.flipCanvas(horizontally: horizontally)
    }
    @objc func deleteLayer(_ sender: Any?) { activeTab?.session.deleteLayerOrMask() }

    // Adjustments, as the Mac's Layer and Image menus have them: as layers, or applied to a layer's own pixels.
    @objc func newAdjustmentLayer(_ sender: UICommand) {
        guard let name = sender.propertyList as? String, let kind = AdjustmentKind(rawValue: name) else { return }
        activeTab?.session.addAdjustment(kind)
    }
    @objc func editAdjustment(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        session.adjustmentEditingID = session.activeLayerID
    }
    @objc func levels(_ sender: Any?) { activeTab?.session.beginLevels() }
    /// The filters and adjustments with an editor on iPad, which the Filter and Image menus offer; the others are listed
    /// there dimmed.
    static var filterEditors: Set<FilterKind> { FilterEditorController.kinds }
    /// A filter or adjustment from the Filter, Image or Edit menu, by its kind.
    @objc func applyFilter(_ sender: UICommand) {
        guard let raw = sender.propertyList as? String, let kind = FilterKind(rawValue: raw), Self.filterEditors.contains(kind) else { return }
        activeTab?.session.beginFilter(kind)
    }
    @objc func curves(_ sender: Any?) { activeTab?.session.beginFilter(.curves) }
    @objc func hueSaturation(_ sender: Any?) { activeTab?.session.beginHueSaturation() }
    @objc func invertPixels(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        Task { await session.invertPixels() }
    }

    // The Select menu and the Edit menu's fills, as on the Mac. A field being edited keeps its own Select All.
    @objc override func selectAll(_ sender: Any?) { activeTab?.session.selectAll() }
    @objc func deselect(_ sender: Any?) { activeTab?.session.deselect() }
    @objc func invertSelection(_ sender: Any?) { activeTab?.session.invertSelection() }
    @objc func selectLayerPixels(_ sender: Any?) {
        guard let session = activeTab?.session, let id = session.activeLayerID else { return }
        session.loadLayerSelection(layerID: id)
    }
    @objc func selectMaskBlackAreas(_ sender: Any?) {
        guard let session = activeTab?.session, let id = session.activeLayerID else { return }
        session.loadMaskSelection(layerID: id)
    }
    @objc func selectSubject(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        Task { await session.selectSubject() }
    }
    @objc func expandSelection(_ sender: Any?) { activeTab?.session.promptSelectionAmount(.expand) }
    @objc func contractSelection(_ sender: Any?) { activeTab?.session.promptSelectionAmount(.contract) }
    @objc func featherSelection(_ sender: Any?) { activeTab?.session.promptSelectionAmount(.feather) }
    @objc func fillWithForeground(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        Task { await session.fillSelection(with: .foreground) }
    }
    @objc func fillWithBackground(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        Task { await session.fillSelection(with: .background) }
    }
    @objc func clearSelectionPixels(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        Task { await session.clearSelectedPixels() }
    }
    /// A layer copied whole comes back as a copy above it; pixels go back where they were copied from; an image another
    /// app copied comes in centered.
    @objc override func paste(_ sender: Any?) {
        guard let session = activeTab?.session else { return }
        if let ids = copiedLayers(in: session) { session.duplicateLayers(ids, editName: "Paste") }
        else if session.canPaste { session.paste() }
        else { Platform.beep() }
    }
    /// The layers Copy took whole from this project, while nothing has been copied since, as the Mac's Paste finds them.
    private func copiedLayers(in session: EditorSession) -> [UUID]? {
        guard session.canEditLayers, let copied = session.copiedLayer, copied.changeCount == SystemPasteboard.changeCount,
              let layers = session.document?.layers else { return nil }
        let ids = copied.ids.filter { id in layers.contains { $0.id == id } }
        return ids.isEmpty ? nil : ids
    }

    /// The canvas's own keys. Beside Hue/Saturation and Curves they work, as on the Mac, and Escape and Return answer
    /// the editor; under Levels, which the Mac's canvas ignores them under, or a dialog, which has its own Return and
    /// Escape, they wait.
    private static let canvasKeys: Set<Selector> = [
        #selector(toolKey(_:)), #selector(eraserKey(_:)), #selector(shapeKindKey(_:)), #selector(swapColorsKey(_:)), #selector(defaultColorsKey(_:)),
        #selector(brushSizeKey(_:)), #selector(escapeKey(_:)), #selector(returnKey(_:)), #selector(deleteKey(_:)), #selector(arrowKey(_:)),
        #selector(toolModeKey(_:)), #selector(opacityKey(_:)), #selector(brushHardnessKey(_:)), #selector(blendModeKey(_:)),
    ]

    /// Whether a field in the window or the text on the canvas has the keyboard, as the Mac asks whether an NSText is
    /// the first responder.
    var isTyping: Bool {
        func typing(in view: UIView) -> Bool {
            (view.isFirstResponder && view is UITextInput) || view.subviews.contains(where: typing)
        }
        return typing(in: view)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let hasFile = activeTab?.document != nil
        let hasDocument = activeTab?.session.document != nil
        let session = activeTab?.session
        if Self.canvasKeys.contains(action) {
            // Beside an adjustment's editor the canvas keeps its keys, as on the Mac, but Levels holds them; over a dialog
            // there are none. Escape and Return are the editor's.
            if let presented = presentedViewController {
                guard let editor = presented as? AdjustmentEditorController else { return false }
                // Escape and Return are the editor's Cancel and OK, as on the Mac.
                if action == #selector(escapeKey(_:)) || action == #selector(returnKey(_:)) { return editor.isOpen }
                // Over what the editor shows, its color picker, there are none, as over any dialog.
                guard editor.presentedViewController == nil, session?.levels == nil else { return false }
            }
            // A stroke being drawn takes no key but Escape, as on the Mac.
            if session?.brushStroke != nil || session?.warpStroke != nil, action != #selector(escapeKey(_:)) { return false }
        }
        // A field or the text being typed that can't cut, copy, paste or select all doesn't pass the key on to the canvas,
        // as on the Mac, where they're the text's whenever it has the keyboard.
        if [#selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)), #selector(selectAll(_:))].contains(action), isTyping {
            return false
        }
        switch action {
        case #selector(saveProject(_:)), #selector(duplicateProject(_:)):
            return hasFile && session?.canStartProjectOperation == true && session?.changedOnDisk == false
        case #selector(renameProject(_:)): return hasFile
        case #selector(exportPNG(_:)), #selector(exportJPEG(_:)), #selector(canvasSize(_:)), #selector(imageSize(_:)):
            return hasDocument && session?.canStartProjectOperation == true && isClear
        case #selector(fitCanvas(_:)), #selector(actualPixels(_:)),
             #selector(zoomIn(_:)), #selector(zoomOut(_:)): return hasDocument
        case #selector(newCanvasTab(_:)), #selector(openProject(_:)), #selector(importImages(_:)), #selector(importPhotos(_:)),
             #selector(openRecentProject(_:)), #selector(closeTab(_:)): return true
        case #selector(clearRecentProjects(_:)): return !PadRecentProjects.shared.urls.isEmpty
        case #selector(cut(_:)): return session.map { $0.selection != nil && $0.canCopyPixels } ?? false
        case #selector(copy(_:)): return session.map { $0.canCopyPixels || $0.canCopyLayer } ?? false
        case #selector(copyMerged(_:)): return session?.canCopyMerged ?? false
        case #selector(paste(_:)): return session.map { copiedLayers(in: $0) != nil || $0.canPaste } ?? false
        case #selector(transformLayer(_:)): return session.map { $0.canTransform || $0.canTransformSelection } ?? false
        case #selector(layerViaCopy(_:)):
            return session.map { $0.canCopyPixels || ($0.selection == nil && $0.canEditLayers && $0.activeLayer != nil) } ?? false
        case #selector(toggleClippingMask(_:)): return session.map { session in session.activeLayerID.map(session.canToggleClippingMask) ?? false } ?? false
        case #selector(groupLayers(_:)), #selector(newBlankLayer(_:)), #selector(flipCanvas(_:)): return session?.canEditLayers ?? false
        case #selector(ungroupLayers(_:)): return session?.canUngroupLayers ?? false
        case #selector(moveOutOfFolder(_:)): return session.map { $0.canEditLayers && $0.activeLayer?.parentID != nil } ?? false
        case #selector(renameLayer(_:)):
            // It asks in an alert, which can't come over another.
            return session.map { $0.canEditLayers && $0.activeLayer != nil } == true && isClear
        case #selector(toggleLayerVisibility(_:)), #selector(deleteLayer(_:)):
            return session.map { $0.canEditLayers && $0.activeLayer != nil } ?? false
        case #selector(moveLayer(_:)):
            guard let offset = (sender as? UICommand)?.propertyList as? Int else { return false }
            return session?.canMoveActiveLayer(by: offset) ?? false
        case #selector(mergeLayers(_:)): return session?.canMergeLayers ?? false
        case #selector(flipLayers(_:)): return session?.canTransform ?? false
        case #selector(toggleView(_:)):
            guard let viewSwitch = ((sender as? UICommand)?.propertyList as? String).flatMap(ViewSwitch.init),
                  viewSwitch.isAvailable else { return false }
            // Snap is the window's, with or without a project; Show Transform Controls is the Move tool's.
            switch viewSwitch {
            case .snapping: return true
            case .transformControls: return hasDocument && session?.tool == .move
            default: return hasDocument
            }
        case #selector(clearGuides(_:)): return session?.canClearGuides ?? false
        case #selector(selectAll(_:)): return hasDocument
        case #selector(deselect(_:)), #selector(invertSelection(_:)):
            return session.map { $0.selection != nil && $0.canEditSelection } ?? false
        case #selector(selectLayerPixels(_:)): return session.map { $0.activeLayer?.asset != nil && $0.canEditSelection } ?? false
        case #selector(selectMaskBlackAreas(_:)): return session.map { $0.activeLayer?.mask != nil && $0.canEditSelection } ?? false
        case #selector(selectSubject(_:)): return session?.canSelectSubject ?? false
        case #selector(expandSelection(_:)), #selector(contractSelection(_:)), #selector(featherSelection(_:)):
            return session?.canModifySelection ?? false
        case #selector(fillWithForeground(_:)), #selector(fillWithBackground(_:)): return session?.canEditPixels ?? false
        case #selector(clearSelectionPixels(_:)): return session.map { $0.selection != nil && $0.canEditPixels } ?? false
        case #selector(newAdjustmentLayer(_:)):
            // The kinds the iPad has an editor for, and Invert, which has nothing to set.
            guard let name = (sender as? UICommand)?.propertyList as? String, let kind = AdjustmentKind(rawValue: name),
                  AdjustmentEditors.kinds.contains(kind) || kind == .invert else { return false }
            return session.map { $0.canEditLayers && $0.document != nil } ?? false
        case #selector(editAdjustment(_:)):
            return session.map { session in
                session.canEditLayers && session.activeLayer?.adjustment.map { AdjustmentEditors.kinds.contains($0.kind) } == true
            } ?? false
        case #selector(levels(_:)), #selector(curves(_:)): return session.map { $0.canAdjustColors && $0.hueSaturation == nil } ?? false
        case #selector(applyFilter(_:)):
            // Never without an editor to close it, since an open filter holds the project.
            guard let session, let raw = (sender as? UICommand)?.propertyList as? String, let kind = FilterKind(rawValue: raw),
                  Self.filterEditors.contains(kind) else { return false }
            if kind == .contentAwareFill { return session.canContentAwareFill }
            return (kind == .vignette ? session.canVignette : session.canAdjustColors) && session.hueSaturation == nil
        case #selector(hueSaturation(_:)): return session?.canAdjustColors ?? false
        case #selector(invertPixels(_:)): return session?.canInvert ?? false
        case #selector(escapeKey(_:)), #selector(returnKey(_:)): return canvasTakes(action)
        case #selector(deleteKey(_:)): return hasDocument
        case #selector(levelsPreviewKey(_:)): return session?.levels != nil
        case #selector(toolModeKey(_:)):
            // Only while the canvas has the keyboard, since it goes before a field's or the text's own Tab.
            return hasDocument && session?.textDraft == nil && (isFirstResponder || activeTab?.canvas.isFirstResponder == true)
        case #selector(opacityKey(_:)): return hasDocument && session?.usesOpacityKeys == true
        case #selector(brushSizeKey(_:)), #selector(brushHardnessKey(_:)): return session?.tool.isBrushTool == true
        case #selector(blendModeKey(_:)): return session?.activeLayer != nil
        case #selector(arrowKey(_:)):
            guard let session, hasDocument else { return false }
            // ⌘ moves the selected pixels with any tool; otherwise a selection tool nudges the outline and Move the layer.
            if (sender as? UIKeyCommand)?.modifierFlags.contains(.command) == true {
                return session.selection?.isEmpty == false && session.lassoDraft == nil
            }
            return session.tool == .move || (session.tool.isSelectionTool && session.selection?.isEmpty == false && session.lassoDraft == nil)
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        // Named as the Mac's Layer menu names them for what they'll do.
        if command.action == #selector(transformLayer(_:)) {
            command.title = activeTab?.session.canTransformSelection == true ? "Transform Selection" : "Transform Layer"
        } else if command.action == #selector(layerViaCopy(_:)) {
            command.title = activeTab?.session.selection == nil ? "Duplicate Layer" : "Layer via Copy"
        } else if command.action == #selector(invertPixels(_:)) {
            command.title = activeTab?.session.isMaskSelected == true ? "Invert Mask" : "Invert"
        } else if command.action == #selector(toggleClippingMask(_:)) {
            command.title = activeTab?.session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask"
        } else if command.action == #selector(toggleLayerVisibility(_:)) {
            command.title = activeTab?.session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer"
        } else if command.action == #selector(mergeLayers(_:)) {
            command.title = activeTab?.session.mergeTitle ?? "Merge Down"
        } else if command.action == #selector(toggleView(_:)), let session = activeTab?.session,
                  let viewSwitch = (command.propertyList as? String).flatMap(ViewSwitch.init), viewSwitch.isAvailable {
            command.state = session[keyPath: viewSwitch.setting] ? .on : .off
        } else if command.action == #selector(deleteLayer(_:)), let session = activeTab?.session {
            command.title = if let effect = session.selectedEffect { "Delete " + effect.kind.rawValue }
                else if session.isMaskSelected && session.activeLayer?.mask != nil { "Delete Layer Mask" }
                else if session.selectedLayerIDs.count > 1 { "Delete Layers" }
                else { "Delete Layer" }
        }
    }

    /// The canvas's keys, as the Mac's Keyboard Shortcuts lists them, on a hardware keyboard.
    override var keyCommands: [UIKeyCommand]? { Self.canvasCommands }

    // Space held down moves the canvas under a touch, as on the Mac. It's no key command: those come when a key goes
    // down, not up. A field or the text being typed takes it as a space before it reaches here.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldKeysChange(presses, down: true, event: event)
        let space = presses.filter { $0.key?.keyCode == .keyboardSpacebar }
        if !space.isEmpty, holdSpace() { takenPresses.formUnion(space) }
        let enter = presses.filter { $0.key?.keyCode == .keypadEnter }
        if !enter.isEmpty, keypadEnter() { takenPresses.formUnion(enter) }
        let rest = presses.subtracting(takenPresses)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        heldKeysChange(presses, down: false, event: event)
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) { releaseSpace() }
        let rest = presses.subtracting(takenPresses)
        takenPresses.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseKeys()
        let rest = presses.subtracting(takenPresses)
        takenPresses.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
    /// Presses the window kept from the responders above it, as Space held for the canvas: they don't hear its end
    /// either.
    private var takenPresses: Set<UIPress> = []
    /// The modifier keys down, left and right apart, as presses reported them.
    private var modifierKeysDown: Set<UIKeyboardHIDUsage> = []
    /// The modifier keys among the keys `presses` put `down` or let up, and the ones the event says are held besides.
    private func heldKeysChange(_ presses: Set<UIPress>, down: Bool, event: UIPressesEvent?) {
        let codes = presses.compactMap { $0.key?.keyCode }
        guard !codes.isEmpty || event != nil else { return }
        holdKeys(Self.heldKeys(event?.modifierFlags ?? heldKeys, changing: codes, down: down, keysDown: &modifierKeysDown))
    }
    /// The modifier keys held once the keys `codes` go `down` or up, from the ones `flags` says are held and those in
    /// `keysDown`, the modifier keys down so far, which it keeps: a key let up while the same one on the keyboard's
    /// other side stays down leaves it held.
    static func heldKeys(_ flags: UIKeyModifierFlags, changing codes: [UIKeyboardHIDUsage], down: Bool,
                         keysDown: inout Set<UIKeyboardHIDUsage>) -> UIKeyModifierFlags {
        var held = flags
        for code in codes {
            guard let flag = modifierKeys[code] else { continue }
            if down {
                keysDown.insert(code)
                held.insert(flag)
            } else {
                keysDown.remove(code)
                if keysDown.contains(where: { modifierKeys[$0] == flag }) { held.insert(flag) } else { held.remove(flag) }
            }
        }
        return held
    }
    private static let modifierKeys: [UIKeyboardHIDUsage: UIKeyModifierFlags] = [
        .keyboardLeftShift: .shift, .keyboardRightShift: .shift, .keyboardLeftAlt: .alternate, .keyboardRightAlt: .alternate,
        .keyboardLeftControl: .control, .keyboardRightControl: .control, .keyboardLeftGUI: .command, .keyboardRightGUI: .command,
    ]
    /// Holds Space down for the canvas in front, when it has the keyboard and no stroke is being drawn, which takes no
    /// key but Escape on the Mac; whether it did.
    func holdSpace() -> Bool {
        guard let tab = activeTab, isFirstResponder || tab.canvas.isFirstResponder,
              tab.session.brushStroke == nil, tab.session.warpStroke == nil else { return false }
        tab.canvas.spaceHeld = true
        return true
    }
    /// The modifier keys held now, for what a held key changes at once, as on the Mac: Shift and Option show the
    /// selection's mode, Command and Shift flip Auto Select and the aspect-ratio lock, Option shows Clone Stamp's
    /// crosshair, and a marquee or crop being dragged follows them.
    private(set) var heldKeys: UIKeyModifierFlags = []
    /// Holds `flags` down, as the keyboard, a touch or the pointer reports them. Keys held while typing in a field or
    /// the text don't count, as on the Mac: ⌘A there shouldn't flicker the options bar.
    func holdKeys(_ flags: UIKeyModifierFlags) {
        let held = isTyping ? [] : flags.intersection([.command, .shift, .alternate, .control])
        guard held != heldKeys else { return }
        heldKeys = held
        optionsBar.heldKeys = held
        activeTab?.session.updateHeldSelectionKeys(shift: held.contains(.shift), option: held.contains(.alternate))
        activeTab?.canvas.keysChanged(held)
    }
    /// Lets go of every key held: they came up, or went with the keyboard or the app.
    func releaseKeys() {
        releaseSpace()
        modifierKeysDown = []
        holdKeys([])
    }
    /// Keypad Enter applies as Return does, as on the Mac; whether it did. It's known by its key, as UIKit may not give
    /// it Return's character, and a field or the text being typed takes it first.
    func keypadEnter() -> Bool {
        guard canPerformAction(#selector(returnKey(_:)), withSender: nil) else { return false }
        returnKey(nil)
        return true
    }
    /// Lets Space go: it came up, or went with the keyboard or the app.
    func releaseSpace() {
        for tab in tabs { tab.canvas.spaceHeld = false }
    }
    /// The keyboard going from the window to a field takes Space's coming up with it, so Space is let go; going to the
    /// canvas, as a touch takes it, Space stays held for the touch.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            Task { @MainActor [weak self] in
                guard let self, let tab = activeTab, !isFirstResponder, !tab.canvas.isFirstResponder else { return }
                releaseKeys()
            }
        }
        return resigned
    }

    /// The canvas's keys, by the names the Mac's Keyboard Shortcuts list gives them. Made once: whether each applies is
    /// asked when it's pressed.
    private static let canvasCommands: [UIKeyCommand] = {
        let tools: [(String, NavigationTool, String)] = [
            ("v", .move, "Move / Transform tool"), ("m", .marquee, "Marquee / cycle shape"), ("l", .lasso, "Lasso / cycle mode"),
            ("w", .wand, "Magic"), ("c", .crop, "Crop tool"), ("b", .brush, "Brush tool"), ("j", .spotHealing, "Spot Healing"),
            ("s", .cloneStamp, "Clone Stamp"), ("r", .blur, "Blur / Smudge / Liquify"), ("g", .gradient, "Gradient tool"),
            ("u", .shape, "Shape tool"), ("t", .type, "Type tool"), ("i", .eyedropper, "Eyedropper tool"), ("h", .hand, "Hand tool"),
            ("z", .zoom, "Zoom tool"), ("a", .idle, "Select tool"),
        ]
        let letters: [UIKeyCommand] = tools.map { key, tool, name in
            UIKeyCommand(title: name, action: #selector(toolKey(_:)), input: key, propertyList: tool.rawValue)
        }
        // Shift with a letter does what the letter does, as on the Mac, which reads it without Shift; Shift-U has its own.
        let shiftedTools: [UIKeyCommand] = tools.filter { $0.0 != "u" }.map { key, tool, _ in
            UIKeyCommand(title: "", action: #selector(toolKey(_:)), input: key, modifierFlags: .shift, propertyList: tool.rawValue)
        }
        let shiftedOthers: [UIKeyCommand] = [("e", #selector(eraserKey(_:))), ("x", #selector(swapColorsKey(_:))),
                                             ("d", #selector(defaultColorsKey(_:)))].map { key, action in
            UIKeyCommand(title: "", action: action, input: key, modifierFlags: .shift)
        }
        let digits: [UIKeyCommand] = (0...9).map { (digit: Int) -> UIKeyCommand in
            UIKeyCommand(title: "Opacity digit \(digit) (type two for exact %)", action: #selector(opacityKey(_:)), input: String(digit),
                         propertyList: NSNumber(value: digit))
        }
        // Tab switches the tool's mode, ahead of the system's own use of it, which would otherwise take it.
        let toolMode = UIKeyCommand(title: "Cycle tool mode", action: #selector(toolModeKey(_:)), input: "\t")
        toolMode.wantsPriorityOverSystemBehavior = true
        let others: [UIKeyCommand] = [
            toolMode,
            UIKeyCommand(title: "Eraser", action: #selector(eraserKey(_:)), input: "e"),
            UIKeyCommand(title: "Cycle shape kind", action: #selector(shapeKindKey(_:)), input: "u", modifierFlags: .shift),
            UIKeyCommand(title: "Swap foreground/background", action: #selector(swapColorsKey(_:)), input: "x"),
            UIKeyCommand(title: "Reset colors", action: #selector(defaultColorsKey(_:)), input: "d"),
            UIKeyCommand(title: "Decrease brush size", action: #selector(brushSizeKey(_:)), input: "[", propertyList: false),
            UIKeyCommand(title: "Increase brush size", action: #selector(brushSizeKey(_:)), input: "]", propertyList: true),
            UIKeyCommand(title: "Decrease brush hardness", action: #selector(brushHardnessKey(_:)), input: "[", modifierFlags: .shift,
                         propertyList: false),
            UIKeyCommand(title: "Increase brush hardness", action: #selector(brushHardnessKey(_:)), input: "]", modifierFlags: .shift,
                         propertyList: true),
            UIKeyCommand(title: "Previous blend mode", action: #selector(blendModeKey(_:)), input: "-", modifierFlags: .shift,
                         propertyList: false),
            UIKeyCommand(title: "Next blend mode", action: #selector(blendModeKey(_:)), input: "=", modifierFlags: .shift,
                         propertyList: true),
            // ⌘+ is ⌘ and Shift with =: it zooms in as ⌘= does, as on the Mac.
            UIKeyCommand(title: "", action: #selector(zoomIn(_:)), input: "=", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Cancel current canvas operation", action: #selector(escapeKey(_:)), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Apply current canvas operation", action: #selector(returnKey(_:)), input: "\r"),
            UIKeyCommand(title: "Delete selection / layer / effect / lasso point", action: #selector(deleteKey(_:)),
                         input: UIKeyCommand.inputDelete),
            UIKeyCommand(title: "Toggle Levels preview", action: #selector(levelsPreviewKey(_:)), input: "p", modifierFlags: .alternate),
        ]
        let arrows: [UIKeyCommand] = [("Left", UIKeyCommand.inputLeftArrow), ("Right", UIKeyCommand.inputRightArrow),
                                      ("Up", UIKeyCommand.inputUpArrow), ("Down", UIKeyCommand.inputDownArrow)].flatMap { name, arrow in
            [([], "Nudge \(name) 1 px"), (.shift, "Nudge \(name) 10 px"), (.command, "Move selected pixels \(name) 1 px"),
             ([.command, .shift], "Move selected pixels \(name) 10 px")].map { (flags: UIKeyModifierFlags, title: String) in
                UIKeyCommand(title: title, action: #selector(arrowKey(_:)), input: arrow, modifierFlags: flags)
            }
        }
        return letters + shiftedTools + shiftedOthers + digits + others + arrows
    }()
    @objc private func toolKey(_ command: UIKeyCommand) {
        guard let raw = command.propertyList as? String, let tool = NavigationTool(rawValue: raw),
              let session = activeTab?.session, session.document != nil else { return }
        session.selectTool(tool)
        if tool == .brush { session.brushMode = .paint }
    }
    @objc private func eraserKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, session.document != nil else { return }
        session.selectTool(.brush)
        session.brushMode = .erase
    }
    /// Shift-U steps the Shape tool through Rectangle, Ellipse and Line, or chooses it, as on the Mac.
    @objc private func shapeKindKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, session.document != nil else { return }
        if session.tool == .shape { session.toggleShapeKind() } else { session.selectTool(.shape) }
    }
    @objc private func swapColorsKey(_ command: UIKeyCommand) { activeTab?.session.swapPaletteColors() }
    @objc private func defaultColorsKey(_ command: UIKeyCommand) { activeTab?.session.resetPaletteColors() }
    @objc private func toolModeKey(_ command: UIKeyCommand) { activeTab?.session.cycleToolMode() }
    /// Option-P turns Levels' preview off and on, as on the Mac.
    @objc private func levelsPreviewKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, let levels = session.levels else { return }
        session.updateLevels(levels.settings, preview: !levels.preview)
    }
    /// 1 to 9 set a tenth to nine tenths, 0 all of it; two typed quickly set the exact percentage, as on the Mac.
    @objc private func opacityKey(_ command: UIKeyCommand) {
        guard let digit = command.propertyList as? Int else { return }
        activeTab?.session.typeOpacityDigit(digit)
    }
    @objc private func brushHardnessKey(_ command: UIKeyCommand) {
        activeTab?.session.changeBrushHardness(increase: command.propertyList as? Bool == true)
    }
    @objc private func blendModeKey(_ command: UIKeyCommand) {
        activeTab?.session.cycleBlendMode(forward: command.propertyList as? Bool == true)
    }
    /// Whether the canvas has an edit under way that Escape or Return (`action`) answers. A stroke takes Escape only,
    /// unless the project is busy; text and a box for it take it too, as on the Mac.
    private func canvasTakes(_ action: Selector) -> Bool {
        guard let tab = activeTab else { return false }
        let session = tab.session
        if action == #selector(escapeKey(_:)) {
            if session.brushStroke != nil || session.warpStroke != nil { return !session.isProjectBusy }
            return tab.canvas.input.textBox != nil || session.textDraft != nil || session.lassoDraft != nil
                || session.shapeDraft != nil || session.gradientEdit != nil || (session.tool == .crop && session.cropRect != nil)
                || session.transformEdit != nil
        }
        return session.brushStroke == nil && session.warpStroke == nil
            && (session.lassoDraft != nil || session.gradientEdit != nil || (session.tool == .crop && session.cropRect != nil)
                || session.transformEdit != nil)
    }

    // Escape, Return, Delete and the arrows on the canvas, in the Mac's order: an outline being drawn first, then a shape
    // or a gradient, a crop, and a transform. The arrows move a step, or ten with Shift: with ⌘ the selected pixels, with a selection tool the
    // outline, and with the Move tool the layer.
    @objc private func escapeKey(_ command: UIKeyCommand) {
        if let editor = presentedViewController as? AdjustmentEditorController {
            // A color being picked first: put back, as the Mac picker's Cancel puts it back.
            if editor.session.colorPicker.map({ AdjustmentEditorController.picks($0.target) }) == true {
                editor.session.closeColorPicker(commit: false)
                return
            }
            // Beside an effect's panel, an edit of the canvas's own first, as on the Mac once the canvas is clicked.
            if !(editor is EffectEditorController && canvasTakes(#selector(escapeKey(_:)))) {
                editor.cancel()
                return
            }
        }
        guard let tab = activeTab else { return }
        let session = tab.session, input = tab.canvas.input
        if input.textBox != nil { input.endDrag(); return }
        if session.textDraft != nil { session.cancelText(); return }
        if session.brushStroke != nil || session.warpStroke != nil {
            if !session.isProjectBusy { session.cancelBrush() }
            return
        }
        // The finger still down draws no new frame or line, as on the Mac.
        input.endDrag()
        if session.lassoDraft != nil { session.cancelLasso() }
        else if session.shapeDraft != nil { session.cancelShape() }
        else if session.gradientEdit != nil { session.cancelGradient() }
        else if session.tool == .crop, session.cropRect != nil { session.cancelCrop() }
        else { session.cancelTransform() }
    }
    @objc private func returnKey(_ sender: Any?) {
        if let editor = presentedViewController as? AdjustmentEditorController {
            // A color being picked first: kept, as the Mac picker's OK keeps it.
            if editor.session.colorPicker.map({ AdjustmentEditorController.picks($0.target) }) == true {
                editor.session.closeColorPicker(commit: true)
                return
            }
            if !(editor is EffectEditorController && canvasTakes(#selector(returnKey(_:)))) {
                editor.commit()
                return
            }
        }
        guard let tab = activeTab else { return }
        let session = tab.session
        tab.canvas.input.endDrag()
        if session.lassoDraft != nil { session.finishLasso() }
        else if session.gradientEdit != nil { Task { await session.commitGradient() } }
        else if session.tool == .crop, session.cropRect != nil { Task { await session.commitCrop() } }
        else { session.commitTransform() }
    }
    /// A polygonal outline's last corner, or else the selection's pixels, or with no selection the layer or mask.
    @objc private func deleteKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session else { return }
        if session.lassoDraft != nil { session.removeLastLassoPoint() } else { session.deleteKeyPressed() }
    }
    @objc private func arrowKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, let arrow = command.input else { return }
        let step: CGFloat = command.modifierFlags.contains(.shift) ? 10 : 1
        let dx = arrow == UIKeyCommand.inputLeftArrow ? -step : arrow == UIKeyCommand.inputRightArrow ? step : 0
        let dy = arrow == UIKeyCommand.inputUpArrow ? -step : arrow == UIKeyCommand.inputDownArrow ? step : 0
        if command.modifierFlags.contains(.command) { Task { await session.nudgePixels(dx: dx, dy: dy) } }
        else if session.tool.isSelectionTool { session.nudgeSelection(dx: dx, dy: dy) }
        else { session.nudgeLayer(dx: dx, dy: dy) }
    }
    @objc private func brushSizeKey(_ command: UIKeyCommand) {
        guard let session = activeTab?.session, session.tool.isBrushTool else { return }
        session.changeBrushSize(increase: command.propertyList as? Bool == true)
    }

    // MARK: Restoration and the app's life

    /// The window's projects and the one in front, to open again when iPadOS brings the window back.
    var restorationActivity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.restorationActivityType)
        let open = tabs.compactMap { tab in tab.url.flatMap { PadRecentProjects.reference(to: $0) }.map { (tab, $0) } }
        activity.addUserInfoEntries(from: [
            "tabs": open.map(\.1),
            "active": open.firstIndex { $0.0.id == activeID } ?? 0,
        ])
        return activity
    }

    func restore(from activity: NSUserActivity) {
        guard activity.activityType == Self.restorationActivityType,
              let references = activity.userInfo?["tabs"] as? [Data], !references.isEmpty else { return }
        // A project moved or deleted since is left out.
        let urls = references.map { PadRecentProjects.resolve($0) }
        urls.forEach { $0.map { open(project: $0) } }
        if let active = activity.userInfo?["active"] as? Int, urls.indices.contains(active), let url = urls[active],
           let tab = tabs.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            select(tab.id)
        }
    }

    /// The save Save or `saveAll` set going last. Tests wait for it.
    private(set) var saving: Task<Void, Never>?

    /// Before iPadOS may quit the app in the background, every changed project is saved, each on its own, with time
    /// asked for to finish. What's in progress stays as it is, for coming back to. An edit already OK'd and still being
    /// worked out goes in first if it's done in a moment, but a dialog left open, which holds its project too, doesn't
    /// hold the save up. Text being typed stays open, as in Apple's own apps, and is saved as Done would put it.
    func saveAll() {
        let tabs = tabs
        saving = Self.withBackgroundTime("Save projects") {
            await withTaskGroup { group in
                for tab in tabs {
                    guard let document = tab.document else { continue }
                    group.addTask { @MainActor in
                        for _ in 0..<20 where tab.session.isProjectBusy { try? await Task.sleep(for: .milliseconds(100)) }
                        // Including an edit just made, which hasn't marked the document changed yet.
                        if tab.session.isModified || tab.session.textDraft != nil { document.updateChangeCount(.done) }
                        _ = await document.autosave()
                    }
                }
            }
        }
    }

    /// The window is gone: a dialog over it ends as its Cancel would, and every tab saves and closes, with time asked
    /// for to finish.
    func closeAll() {
        cancelDialog()
        let tabs = tabs
        _ = Self.withBackgroundTime("Close projects") {
            await withTaskGroup { group in
                for tab in tabs { group.addTask { await tab.close() } }
            }
        }
    }

    /// The project whose dialog is over the window, or was last.
    private weak var dialogSession: EditorSession?

    /// Ends a dialog over the window as its Cancel would, freeing the project it holds.
    private func cancelDialog() {
        switch presentedViewController {
        case let dialog as SizeDialogController: dialog.cancel()
        case let dialog as JPEGExportController: dialog.cancel()
        default: break
        }
    }

    /// Runs `work`, with time asked of iPadOS to finish it should the app leave the screen meanwhile.
    private static func withBackgroundTime(_ name: String, _ work: @escaping () async -> Void) -> Task<Void, Never> {
        final class Identifier { var value = UIBackgroundTaskIdentifier.invalid }
        let identifier = Identifier()
        let end = {
            guard identifier.value != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier.value)
            identifier.value = .invalid
        }
        identifier.value = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: end)
        return Task {
            await work()
            end()
        }
    }

    // MARK: Helpers

    /// A toolbar item acting on the tab in front's editor.
    private func barItem(title: String? = nil, symbol: String? = nil, label: String,
                         action: @escaping (EditorSession) -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, primaryAction: UIAction { [weak self] _ in
            guard let session = self?.activeTab?.session else { return }
            action(session)
        })
        item.accessibilityLabel = label
        return item
    }

    private func presentSheet(_ controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showError(_ title: String, _ error: any Error) { showMessage(title, error.localizedDescription) }

    /// Says `message` over whatever the window shows, or, `overWhatsShown` false, from the window itself, so an
    /// effect's panel gives way to it as to anything else.
    private func showMessage(_ title: String, _ message: String, overWhatsShown: Bool = true) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (overWhatsShown ? presentedViewController ?? self : self).present(alert, animated: true)
    }

    /// A one-point line between regions, as the Mac's dividers are.
    static func separator(vertical: Bool) -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor(white: 1, alpha: 0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        (vertical ? line.widthAnchor : line.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return line
    }
}
