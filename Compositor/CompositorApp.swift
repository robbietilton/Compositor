import SwiftUI
import UniformTypeIdentifiers
import Sparkle

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    @AppStorage("navigator.visible") private var showsNavigator = false
    @State private var languageManager = LanguageManager.shared
    private var session: EditorSession { applicationDelegate.session }
    var body: some Scene {
        Window("Compositor", id: "editor") {
            ProjectWorkspaceView(applicationDelegate: applicationDelegate)
                .roundedControls()
                .id(languageManager.revision)
                .task {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await languageManager.prepare()
                }
        }
            .defaultSize(width: 1180, height: 780)
            // Files opened from Finder or dropped on the Dock icon go to the app delegate, which imports them into
            // the open window. Left to SwiftUI, each one builds a throwaway window and fades the editor out and back.
            .handlesExternalEvents(matching: [])
            // A first launch fills the screen (without going full screen); after that macOS reopens the window at the
            // size it was left.
            .defaultWindowPlacement { _, context in
                WindowPlacement(size: context.defaultDisplay.visibleRect.size)
            }
            // The project's name is already on its tab, so the toolbar doesn't repeat it as a window title.
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .environment(\.locale, languageManager.locale)
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    // Dialog text fields keep native text undo; document history
                    // is unavailable while an import or modal edit is active.
                    if session.textDraft != nil || session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                        Button(L10n.string("Undo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z")
                        Button(L10n.string("Redo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
                            }
                        }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift])
                    } else {
                        Button(session.history.canUndo ? L10n.string("Undo") + " " + L10n.string(session.history.undoName) : L10n.string("Undo")) { session.undo() }
                            .configuredKeyboardShortcut("z").disabled(!session.canUndo)
                        Button(session.history.canRedo ? L10n.string("Redo") + " " + L10n.string(session.history.redoName) : L10n.string("Redo")) { session.redo() }
                            .configuredKeyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button(L10n.string("New Canvas…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }.configuredKeyboardShortcut("n")
                        .disabled(!applicationDelegate.projects.canStart)
                    Button(L10n.string("Open Project…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                        .configuredKeyboardShortcut("o").disabled(!applicationDelegate.projects.canStart)
                    Menu(L10n.string("Open Recent")) {
                        ForEach(RecentProjects.shared.urls, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                applicationDelegate.showEditor?()
                                Task { await applicationDelegate.projects.open(url) }
                            }
                        }
                        Divider()
                        Button(L10n.string("Clear Menu")) { RecentProjects.shared.clear() }
                            .disabled(RecentProjects.shared.urls.isEmpty)
                    }
                        .disabled(!applicationDelegate.projects.canStart)
                    Button(L10n.string("Import Images…")) { session.showsImporter = true }
                        .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
                }
                CommandGroup(replacing: .saveItem) {
                    Button(L10n.string("Save")) { Task { await applicationDelegate.projects.save() } }
                        .configuredKeyboardShortcut("s").disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Save As…")) { Task { await applicationDelegate.projects.save(asNew: true) } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    // Export As on JPEG.
                    Button(L10n.string("Export JPEG…")) { Task { await applicationDelegate.projects.exportAs(start: .jpeg) } }
                        .configuredKeyboardShortcut("s", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Export PNG…")) { Task { await applicationDelegate.projects.exportPNG() } }
                        .configuredKeyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    // PNG, JPEG or PDF, sized and previewed; ⌥⇧⌘W, as Photoshop's Export As.
                    Button(L10n.string("Export As…")) { Task { await applicationDelegate.projects.exportAs() } }
                        .configuredKeyboardShortcut("w", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button(L10n.string("Close Project")) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }.configuredKeyboardShortcut("w").disabled(!applicationDelegate.projects.canStart)
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .appInfo) {
                        Button(L10n.string("Check for Updates…")) { applicationDelegate.updater.checkForUpdates() }
                        Button(L10n.string("MCP Server…")) { applicationDelegate.mcpServer.showSettings() }
                    }
                    CommandGroup(after: .toolbar) {
                        Button(L10n.string("Search Commands…")) {
                            CommandPaletteController.shared.toggle(session: session, over: applicationDelegate.projects.window)
                        }
                        .configuredKeyboardShortcut("f", modifiers: [.command])
                        // A plain F, shown as menus show keys; the app hands an F meant for a text field to the field
                        // first (see CompositorApplicationDelegate).
                        Toggle(L10n.string("Toggle Fullscreen"), isOn: Binding(get: { session.canvasOnly },
                                                            set: { _ in applicationDelegate.toggleCanvasOnly() }))
                            .keyboardShortcut("f", modifiers: [])
                            .disabled(!session.canToggleCanvasOnly)
                        Divider()
                        // With a dialog's preview open (Export As), these zoom that preview rather than the canvas.
                        Button(L10n.string("Fit Canvas")) {
                            if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
                        }.configuredKeyboardShortcut("0").disabled(session.document == nil)
                        Button(L10n.string("Actual Pixels")) {
                            if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
                        }.configuredKeyboardShortcut("1").disabled(session.document == nil)
                        Button(L10n.string("Zoom In")) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
                        }
                            .configuredKeyboardShortcut("=").disabled(session.document == nil)
                        Button(L10n.string("Zoom Out")) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
                        }
                            .configuredKeyboardShortcut("-").disabled(session.document == nil)
                        Toggle(L10n.string("Navigator (300% and above)"), isOn: $showsNavigator)
                        Toggle(L10n.string("Pixel Grid (800% and above)"), isOn: Binding(get: { session.showsPixelGrid },
                                                                              set: { session.showsPixelGrid = $0 }))
                        Toggle(L10n.string("Show Transform Controls"), isOn: Binding(get: { session.showsTransformControls },
                                                                          set: { session.showsTransformControls = $0 }))
                            .configuredKeyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
                        Menu(L10n.string("Channel")) {
                            Button(L10n.string("RGB")) { session.canvasChannel = .rgb }
                                .configuredKeyboardShortcut("2")
                            Button(L10n.string("Red")) { session.canvasChannel = .red }
                                .configuredKeyboardShortcut("3")
                            Button(L10n.string("Green")) { session.canvasChannel = .green }
                                .configuredKeyboardShortcut("4")
                            Button(L10n.string("Blue")) { session.canvasChannel = .blue }
                                .configuredKeyboardShortcut("5")
                        }.disabled(session.document == nil)
                        Divider()
                        // Print: the canvas as the chosen CMYK profile will print it, tucked in a submenu as few need it. No
                        // shortcuts (Photoshop's ⌘Y sits by ⌘U and would be hit by mistake); Search Commands finds them.
                        Menu(L10n.string("CMYK")) {
                            Toggle(L10n.string("Proof Colors"), isOn: Binding(get: { session.proofsColors }, set: { session.proofsColors = $0 }))
                                .disabled(session.document == nil)
                            Toggle(L10n.string("Gamut Warning"), isOn: Binding(get: { session.showsGamutWarning },
                                                                               set: { session.showsGamutWarning = $0 }))
                                .disabled(session.document == nil)
                            Divider()
                            Menu(L10n.string("Profile")) {
                                let current = session.proofProfile ?? CMYK.chosen
                                ForEach(CMYK.installed()) { profile in
                                    Toggle(profile.name, isOn: Binding(get: { current?.name == profile.name },
                                                                       set: { if $0 { session.proofProfile = profile } }))
                                }
                                Divider()
                                Button(L10n.string("Load Profile…")) { loadCMYKProfile() }
                            }
                        }
                        Group {
                            Divider()
                            Menu(L10n.string("Show")) {
                                Toggle(L10n.string("Grid"), isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                                    .configuredKeyboardShortcut("'").disabled(session.document == nil)
                                Toggle(L10n.string("Guides"), isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                                    .configuredKeyboardShortcut(";").disabled(session.document == nil)
                            }
                            Button(L10n.string("Grid Settings…")) { Task { await applicationDelegate.projects.gridSettings() } }
                                .disabled(session.document == nil)
                            Toggle(L10n.string("Rulers"), isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                                .configuredKeyboardShortcut("r").disabled(session.document == nil)
                            Divider()
                            Toggle(L10n.string("Snap"), isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .shift]).disabled(session.document == nil)
                            Menu(L10n.string("Snap To")) {
                                Toggle(L10n.string("Guides"), isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(L10n.string("Grid"), isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(L10n.string("Layers"), isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                                    .disabled(session.document == nil)
                                Toggle(L10n.string("Document Bounds"), isOn: Binding(get: { session.snapToDocumentBounds },
                                                                        set: { session.snapToDocumentBounds = $0 }))
                                    .disabled(session.document == nil)
                            }
                            Divider()
                            Toggle(L10n.string("Lock Guides"), isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                                .configuredKeyboardShortcut(";", modifiers: [.command, .option]).disabled(session.document == nil)
                            Button(L10n.string("Clear Guides")) { session.clearGuides() }
                                .disabled(!session.canClearGuides)
                        }
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        Button(L10n.string("Hide Compositor")) { NSApp.hide(nil) }
                        Button(L10n.string("Hide Others")) { NSApp.hideOtherApplications(nil) }
                            .configuredKeyboardShortcut("h", modifiers: [.command, .option])
                        Button(L10n.string("Show All")) { NSApp.unhideAllApplications(nil) }
                    }
                }
                CommandGroup(replacing: .pasteboard) {
                    // Canvas pixels when the canvas has focus; text fields keep their own editing.
                    // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
                    // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
                    // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
                    Button(L10n.string("Cut")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("x")
                    Button(L10n.string("Copy")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("c")
                    Button(L10n.string("Copy Merged")) { session.copyMergedSelection() }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
                    Button(L10n.string("Paste")) {
                        // On the New canvas screen an image on the clipboard makes the canvas, even with a size field
                        // being typed in; a size copied as text still goes into the field.
                        if session.canPasteImageAsNewCanvas { Task { await session.pasteImageAsNewCanvas() } }
                        else if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if applicationDelegate.workspace.pasteCopiedLayer() { }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                        .configuredKeyboardShortcut("v")
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    Button(L10n.string("Keyboard Shortcuts…")) { ShortcutSettings.shared.show() }
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    Button(L10n.string("Fill with Foreground Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
                    Button(L10n.string("Fill with Background Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                        .configuredKeyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
                    Button(L10n.string("Clear Selection Pixels")) { Task { await session.clearSelectedPixels() } }
                        .disabled(session.selection == nil || !session.canEditPixels)
                    Button(L10n.string("Content-Aware Fill…")) { session.beginFilter(.contentAwareFill) }
                        .configuredKeyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
                }
                CommandMenu(L10n.string("Select")) {
                    // A field being edited keeps its own Select All: offer it to the responder chain
                    // first, which covers every kind of text control rather than NSTextView alone,
                    // and select the canvas only when nothing there wanted it.
                    Button(L10n.string("All")) {
                        if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) { return }
                        guard session.document != nil else { return }
                        session.selectAll()
                    }
                        // Never disabled: on macOS this menu item is what binds Cmd-A to selectAll:, so
                        // switching it off takes Select All away from every text field too. With no
                        // document and nothing being edited the action simply does nothing.
                        .configuredKeyboardShortcut("a")
                    Button(L10n.string("Deselect")) { session.deselect() }
                        .configuredKeyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
                    Button(L10n.string("Inverse")) { session.invertSelection() }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(session.selection == nil || !session.canEditSelection)
                    Button(L10n.string("Layer's Pixels")) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
                    Button(L10n.string("Subject")) { Task { await session.selectSubject() } }
                        .configuredKeyboardShortcut("a", modifiers: [.command, .option])
                        .disabled(!session.canSelectSubject)
                    Button(L10n.string("Color Range…")) { Task { await session.beginColorRange() } }
                        .disabled(!session.canSelectColorRange)
                    Button(L10n.string("Mask's Black Areas")) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.mask == nil || !session.canEditSelection)
                    Divider()
                    Button(L10n.string("Expand…")) { session.promptSelectionAmount(.expand) }
                        .disabled(!session.canModifySelection)
                    Button(L10n.string("Contract…")) { session.promptSelectionAmount(.contract) }
                        .disabled(!session.canModifySelection)
                    Button(L10n.string("Feather…")) { session.promptSelectionAmount(.feather) }
                        .disabled(!session.canModifySelection)
                }
                CommandMenu(L10n.string("Image")) {
                    Button(L10n.string("Curves…")) { session.beginFilter(.curves) }
                        .configuredKeyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(L10n.string("Levels…")) { session.beginLevels() }
                        .configuredKeyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(L10n.string("Hue/Saturation…")) { session.beginHueSaturation() }
                        .configuredKeyboardShortcut("u").disabled(!session.canAdjustColors)
                    ForEach([FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain], id: \.self) { kind in
                        Button(L10n.string(kind.rawValue) + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                    Button(L10n.string(session.isMaskSelected ? "Invert Mask" : "Invert")) { Task { await session.invertPixels() } }
                        .configuredKeyboardShortcut("i")
                        .disabled(!session.canInvert)
                    Divider()
                    Button(L10n.string("Canvas Size…")) { Task { await applicationDelegate.projects.canvasSize() } }
                        .configuredKeyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Image Size…")) { Task { await applicationDelegate.projects.imageSize() } }
                        .configuredKeyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Trim…")) { Task { await applicationDelegate.projects.trim() } }
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Group {
                        Divider()
                        Button(L10n.string("Rotate Canvas 90° Clockwise")) { session.rotateCanvas(clockwise: true) }
                            .disabled(!session.canEditLayers)
                        Button(L10n.string("Rotate Canvas 90° Counterclockwise")) { session.rotateCanvas(clockwise: false) }
                            .disabled(!session.canEditLayers)
                        Button(L10n.string("Flip Canvas Horizontal")) { session.flipCanvas(horizontally: true) }
                            .disabled(!session.canEditLayers)
                        Button(L10n.string("Flip Canvas Vertical")) { session.flipCanvas(horizontally: false) }
                            .disabled(!session.canEditLayers)
                    }
                }
                Group {
                CommandMenu(L10n.string("Filter")) {
                    Button(session.lastFilter.map { L10n.string("Last Filter:") + " " + L10n.string($0.rawValue) } ?? L10n.string("Last Filter")) {
                        Task { await session.repeatLastFilter() }
                    }
                        // ⌃⌘F, as in Photoshop; ⌘F is the command palette.
                        .configuredKeyboardShortcut("f", modifiers: [.command, .control]).disabled(!session.canRepeatLastFilter)
                    Divider()
                    ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                        Button(L10n.string(kind.rawValue) + "…") { session.beginFilter(kind) }
                            .disabled(!(kind == .vignette ? session.canVignette : session.canAdjustColors) || session.hueSaturation != nil)
                    }
                }
                CommandMenu(L10n.string("Layer")) {
                    Menu(L10n.string("New Adjustment Layer")) {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            Button(L10n.string(kind.rawValue) + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    Button(L10n.string("Edit Adjustment…")) {
                        session.adjustmentEditingID = session.activeLayerID
                    }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
                    Divider()
                    Button(L10n.string(session.canTransformSelection ? "Transform Selection" : "Transform Layer")) { session.transformCommand() }
                        .configuredKeyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
                    Button(L10n.string(session.selection == nil ? "Duplicate Layer" : "Layer via Copy")) { session.layerViaCopy() }
                        .configuredKeyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil))
                    Divider()
                    Button(L10n.string(session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask")) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    .configuredKeyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
                    Divider()
                    Button(L10n.string("Group Selected Layers")) { session.groupSelectedLayers() }
                        .configuredKeyboardShortcut("g").disabled(!session.canEditLayers)
                    Button(L10n.string("Ungroup Layers")) { session.ungroupLayers() }
                        .configuredKeyboardShortcut("g", modifiers: [.command, .shift]).disabled(!session.canUngroupLayers)
                    Button(L10n.string("Move Out of Folder")) { session.moveActiveLayerOutOfGroup() }
                        .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
                    Button(L10n.string("New Blank Layer")) { session.addBlankLayer() }
                        .configuredKeyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
                    Button(L10n.string("Rename Layer…")) { session.renamingLayerID = session.activeLayerID }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                    Button(L10n.string(session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer")) {
                        if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
                    }.disabled(!session.canEditLayers || session.activeLayer == nil)
                    Divider()
                    Button(L10n.string("Move Layer Up")) { session.moveActiveLayer(by: 1) }
                        .configuredKeyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
                    Button(L10n.string("Move Layer Down")) { session.moveActiveLayer(by: -1) }
                        .configuredKeyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
                    Group {
                        Button(L10n.string(session.mergeTitle)) { session.mergeLayers() }
                            .configuredKeyboardShortcut("e").disabled(!session.canMergeLayers)
                        Divider()
                        Button(L10n.string("Flip Layer Horizontal")) { session.flipLayers(horizontally: true) }
                            .disabled(!session.canTransform)
                        Button(L10n.string("Flip Layer Vertical")) { session.flipLayers(horizontally: false) }
                            .disabled(!session.canTransform)
                    }
                    Divider()
                    Button(session.selectedEffect.map { L10n.string("Delete") + " " + L10n.string($0.kind.rawValue) }
                           ?? L10n.string(session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask"
                                          : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer")) {
                        session.deleteLayerOrMask()
                    }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                }
                CommandGroup(after: .help) {
                    Divider()
                    Menu(L10n.string("Language")) {
                        ForEach(languageManager.availableLanguages) { option in
                            Button {
                                Task {
                                    await languageManager.select(option)
                                    if let message = languageManager.lastError {
                                        let alert = NSAlert()
                                        alert.messageText = L10n.string("Language Download Failed")
                                        alert.informativeText = message
                                        alert.alertStyle = .warning
                                        alert.addButton(withTitle: L10n.string("OK"))
                                        alert.runModal()
                                    }
                                }
                            } label: {
                                if languageManager.downloadingLanguageCode == option.code {
                                    Label {
                                        Text(verbatim: option.displayName)
                                    } icon: {
                                        ProgressView().controlSize(.small)
                                    }
                                } else if option.code == languageManager.activeLanguage.code {
                                    Label {
                                        Text(verbatim: option.displayName)
                                    } icon: {
                                        Image(systemName: "checkmark")
                                    }
                                } else {
                                    Text(verbatim: option.displayName)
                                }
                            }
                        }
                    }
                }
                }
            }
    }

    /// View › CMYK › Profile › Load Profile: a CMYK ICC profile picked from anywhere, kept and chosen.
    private func loadCMYKProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = L10n.string("Choose a CMYK ICC profile, such as the one your printer gave you")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { session.proofProfile = try CMYK.load(url) }
        catch { session.importError = error.localizedDescription }
    }
}
