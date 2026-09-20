import SwiftUI
import Sparkle

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    private var session: EditorSession { applicationDelegate.session }
    var body: some Scene {
        Window("Compositor", id: "editor") {
            ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
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
            .commands {
                CommandGroup(replacing: .undoRedo) {
                    // Dialog text fields keep native text undo; document history
                    // is unavailable while an import or modal edit is active.
                    if session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                        Button(L10n.string("Undo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                            }
                        }
                            .keyboardShortcut("z")
                        Button(L10n.string("Redo")) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                            }
                        }
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                    } else {
                        Button(session.history.canUndo ? L10n.format("Undo %1$@", session.history.undoName) : L10n.string("Undo")) { session.undo() }
                            .keyboardShortcut("z").disabled(!session.canUndo)
                        Button(session.history.canRedo ? L10n.format("Redo %1$@", session.history.redoName) : L10n.string("Redo")) { session.redo() }
                            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button(L10n.string("New Canvas…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }.keyboardShortcut("n")
                        .disabled(!applicationDelegate.projects.canStart)
                    Button(L10n.string("Open Project…")) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                        .keyboardShortcut("o").disabled(!applicationDelegate.projects.canStart)
                    Button(L10n.string("Import Images…")) { session.showsImporter = true }
                        .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
                }
                CommandGroup(replacing: .saveItem) {
                    Button(L10n.string("Save")) { Task { await applicationDelegate.projects.save() } }
                        .keyboardShortcut("s").disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Save As…")) { Task { await applicationDelegate.projects.save(asNew: true) } }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button(L10n.string("Export PNG…")) { Task { await applicationDelegate.projects.exportPNG() } }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Export JPEG…")) { Task { await applicationDelegate.projects.exportJPEG() } }
                        .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button(L10n.string("Close Project")) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }.keyboardShortcut("w").disabled(!applicationDelegate.projects.canStart)
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .appInfo) {
                        Button(L10n.string("Check for Updates…")) { applicationDelegate.updater.checkForUpdates(nil) }
                    }
                    CommandGroup(after: .toolbar) {
                        Button(L10n.string("Fit Canvas")) { session.fit() }.keyboardShortcut("0").disabled(session.document == nil)
                        Button(L10n.string("Actual Pixels")) { session.zoom(to: 1) }.keyboardShortcut("1").disabled(session.document == nil)
                        Button(L10n.string("Zoom In")) { session.zoom(to: session.viewport.zoom * 1.25) }
                            .keyboardShortcut("=").disabled(session.document == nil)
                        Button(L10n.string("Zoom Out")) { session.zoom(to: session.viewport.zoom / 1.25) }
                            .keyboardShortcut("-").disabled(session.document == nil)
                        Toggle(L10n.string("Pixel Grid (800% and above)"), isOn: Binding(get: { session.showsPixelGrid },
                                                                              set: { session.showsPixelGrid = $0 }))
                        Toggle(L10n.string("Show Transform Controls"), isOn: Binding(get: { session.showsTransformControls },
                                                                          set: { session.showsTransformControls = $0 }))
                            .keyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        Button(L10n.string("Hide Compositor")) { NSApp.hide(nil) }
                        Button(L10n.string("Hide Others")) { NSApp.hideOtherApplications(nil) }
                            .keyboardShortcut("h", modifiers: [.command, .option])
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
                        .keyboardShortcut("x")
                    Button(L10n.string("Copy")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels { session.copySelection() }
                        else { NSSound.beep() }
                    }
                        .keyboardShortcut("c")
                    Button(L10n.string("Copy Merged")) { session.copyMergedSelection() }
                        .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
                    Button(L10n.string("Paste")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                        .keyboardShortcut("v")
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    Button(L10n.string("Fill with Foreground Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                        .keyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
                    Button(L10n.string("Fill with Background Color")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                        .keyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
                    Button(L10n.string("Clear Selection Pixels")) { Task { await session.clearSelectedPixels() } }
                        .disabled(session.selection == nil || !session.canEditPixels)
                    Button(L10n.string("Content-Aware Fill…")) { session.beginFilter(.contentAwareFill) }
                        .keyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
                }
                CommandMenu(L10n.string("Select")) {
                    // Text fields keep their own Select All.
                    Button(L10n.string("All")) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        } else { session.selectAll() }
                    }
                        .keyboardShortcut("a").disabled(session.document == nil)
                    Button(L10n.string("Deselect")) { session.deselect() }
                        .keyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
                    Button(L10n.string("Inverse")) { session.invertSelection() }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(session.selection == nil || !session.canEditSelection)
                    Button(L10n.string("Layer's Pixels")) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
                    Button(L10n.string("Mask's Black Areas")) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.mask == nil || !session.canEditSelection)
                    Divider()
                    Button(L10n.format("Expand by %1$@ px", String(session.selectionExpandAmount))) { session.expandSelection(by: session.selectionExpandAmount) }
                        .disabled(!session.canModifySelection)
                    Button(L10n.format("Contract by %1$@ px", String(session.selectionContractAmount))) { session.contractSelection(by: session.selectionContractAmount) }
                        .disabled(!session.canModifySelection)
                }
                CommandMenu(L10n.string("Image")) {
                    Button(L10n.string("Curves…")) { session.beginFilter(.curves) }
                        .keyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(L10n.string("Levels…")) { session.beginLevels() }
                        .keyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button(L10n.string("Hue/Saturation…")) { session.beginHueSaturation() }
                        .keyboardShortcut("u").disabled(!session.canAdjustColors)
                    ForEach([FilterKind.exposure, .gradientMap, .grain], id: \.self) { kind in
                        Button(L10n.string(kind.rawValue) + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                    Button(session.isMaskSelected ? L10n.string("Invert Mask") : L10n.string("Invert")) { Task { await session.invertPixels() } }
                        .keyboardShortcut("i")
                        .disabled(!session.canInvert)
                    Divider()
                    Button(L10n.string("Canvas Size…")) { Task { await applicationDelegate.projects.canvasSize() } }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button(L10n.string("Image Size…")) { Task { await applicationDelegate.projects.imageSize() } }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Group {
                        Divider()
                        Button(L10n.string("Flip Canvas Horizontal")) { session.flipCanvas(horizontally: true) }
                            .disabled(!session.canEditLayers)
                        Button(L10n.string("Flip Canvas Vertical")) { session.flipCanvas(horizontally: false) }
                            .disabled(!session.canEditLayers)
                    }
                }
                CommandMenu(L10n.string("Filter")) {
                    ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                        Button(L10n.string(kind.rawValue) + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                }
                CommandMenu(L10n.string("Layer")) {
                    Menu(L10n.string("New Adjustment Layer")) {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            Button(L10n.string(kind.rawValue) + "…") { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    Button(L10n.string("Edit Adjustment…")) {
                        session.adjustmentEditingID = session.activeLayerID
                    }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
                    Divider()
                    Button(session.canTransformSelection ? L10n.string("Transform Selection") : L10n.string("Transform Layer")) { session.transformCommand() }
                        .keyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
                    Button(session.selection == nil ? L10n.string("Duplicate Layer") : L10n.string("Layer via Copy")) { session.layerViaCopy() }
                        .keyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer?.isGroup == false))
                    Divider()
                    Button(session.activeLayer?.maskSourceID == nil ? L10n.string("Create Clipping Mask") : L10n.string("Release Clipping Mask")) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
                    Divider()
                    Button(L10n.string("Group Selected Layers")) { session.groupSelectedLayers() }
                        .keyboardShortcut("g").disabled(!session.canEditLayers)
                    Button(L10n.string("Move Out of Folder")) { session.moveActiveLayerOutOfGroup() }
                        .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
                    Button(L10n.string("New Blank Layer")) { session.addBlankLayer() }
                        .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
                    Button(L10n.string("Rename Layer…")) { session.renamingLayerID = session.activeLayerID }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                    Button(session.activeLayer?.isVisible == false ? L10n.string("Show Layer") : L10n.string("Hide Layer")) {
                        if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
                    }.disabled(!session.canEditLayers || session.activeLayer == nil)
                    Divider()
                    Button(L10n.string("Move Layer Up")) { session.moveActiveLayer(by: 1) }
                        .keyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
                    Button(L10n.string("Move Layer Down")) { session.moveActiveLayer(by: -1) }
                        .keyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
                    Group {
                        Button(session.mergeTitle) { session.mergeLayers() }
                            .keyboardShortcut("e").disabled(!session.canMergeLayers)
                        Divider()
                        Button(L10n.string("Flip Layer Horizontal")) { session.flipLayers(horizontally: true) }
                            .disabled(!session.canTransform)
                        Button(L10n.string("Flip Layer Vertical")) { session.flipLayers(horizontally: false) }
                            .disabled(!session.canTransform)
                    }
                    Divider()
                    Button(session.isMaskSelected && session.activeLayer?.mask != nil ? L10n.string("Delete Layer Mask") : session.selectedLayerIDs.count > 1 ? L10n.string("Delete Layers") : L10n.string("Delete Layer")) {
                        session.deleteLayerOrMask()
                    }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                }
            }
    }
}
