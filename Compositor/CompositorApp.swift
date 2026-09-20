import SwiftUI
import Sparkle

extension String {
    nonisolated var localized: String { String(localized: String.LocalizationValue(self)) }
}

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
                        Button("Undo") {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                            }
                        }
                            .keyboardShortcut("z")
                        Button("Redo") {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                            }
                        }
                            .keyboardShortcut("z", modifiers: [.command, .shift])
                    } else {
                        Button(session.history.canUndo ? String(localized: "Undo \(session.history.undoName)") : String(localized: "Undo")) { session.undo() }
                            .keyboardShortcut("z").disabled(!session.canUndo)
                        Button(session.history.canRedo ? String(localized: "Redo \(session.history.redoName)") : String(localized: "Redo")) { session.redo() }
                            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
                    }
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Canvas…") {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }.keyboardShortcut("n")
                        .disabled(!applicationDelegate.projects.canStart)
                    Button("Open Project…") {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                        .keyboardShortcut("o").disabled(!applicationDelegate.projects.canStart)
                    Button("Import Images…") { session.showsImporter = true }
                        .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("Save") { Task { await applicationDelegate.projects.save() } }
                        .keyboardShortcut("s").disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Save As…") { Task { await applicationDelegate.projects.save(asNew: true) } }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button("Export PNG…") { Task { await applicationDelegate.projects.exportPNG() } }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Export JPEG…") { Task { await applicationDelegate.projects.exportJPEG() } }
                        .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Divider()
                    Button("Close Project") {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }.keyboardShortcut("w").disabled(!applicationDelegate.projects.canStart)
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .appInfo) {
                        Button("Check for Updates…") { applicationDelegate.updater.checkForUpdates(nil) }
                    }
                    CommandGroup(after: .toolbar) {
                        Button("Fit Canvas") { session.fit() }.keyboardShortcut("0").disabled(session.document == nil)
                        Button("Actual Pixels") { session.zoom(to: 1) }.keyboardShortcut("1").disabled(session.document == nil)
                        Button("Zoom In") { session.zoom(to: session.viewport.zoom * 1.25) }
                            .keyboardShortcut("=").disabled(session.document == nil)
                        Button("Zoom Out") { session.zoom(to: session.viewport.zoom / 1.25) }
                            .keyboardShortcut("-").disabled(session.document == nil)
                        Toggle("Pixel Grid (800% and above)", isOn: Binding(get: { session.showsPixelGrid },
                                                                              set: { session.showsPixelGrid = $0 }))
                        Toggle("Show Transform Controls", isOn: Binding(get: { session.showsTransformControls },
                                                                          set: { session.showsTransformControls = $0 }))
                            .keyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        Button("Hide Compositor") { NSApp.hide(nil) }
                        Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                            .keyboardShortcut("h", modifiers: [.command, .option])
                        Button("Show All") { NSApp.unhideAllApplications(nil) }
                    }
                }
                CommandGroup(replacing: .pasteboard) {
                    // Canvas pixels when the canvas has focus; text fields keep their own editing.
                    // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
                    // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
                    // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
                    Button("Cut") {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                        else { NSSound.beep() }
                    }
                        .keyboardShortcut("x")
                    Button("Copy") {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels { session.copySelection() }
                        else { NSSound.beep() }
                    }
                        .keyboardShortcut("c")
                    Button("Copy Merged") { session.copyMergedSelection() }
                        .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
                    Button("Paste") {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                        .keyboardShortcut("v")
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    Button("Fill with Foreground Color") {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                        .keyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
                    Button("Fill with Background Color") {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                        .keyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
                    Button("Clear Selection Pixels") { Task { await session.clearSelectedPixels() } }
                        .disabled(session.selection == nil || !session.canEditPixels)
                    Button("Content-Aware Fill…") { session.beginFilter(.contentAwareFill) }
                        .keyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
                }
                CommandMenu("Select") {
                    // Text fields keep their own Select All.
                    Button("All") {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        } else { session.selectAll() }
                    }
                        .keyboardShortcut("a").disabled(session.document == nil)
                    Button("Deselect") { session.deselect() }
                        .keyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
                    Button("Inverse") { session.invertSelection() }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                        .disabled(session.selection == nil || !session.canEditSelection)
                    Button("Layer's Pixels") {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
                    Button("Mask's Black Areas") {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                        .disabled(session.activeLayer?.mask == nil || !session.canEditSelection)
                    Divider()
                    Button("Expand by \(session.selectionExpandAmount) px") { session.expandSelection(by: session.selectionExpandAmount) }
                        .disabled(!session.canModifySelection)
                    Button("Contract by \(session.selectionContractAmount) px") { session.contractSelection(by: session.selectionContractAmount) }
                        .disabled(!session.canModifySelection)
                }
                CommandMenu("Image") {
                    Button("Curves…") { session.beginFilter(.curves) }
                        .keyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button("Levels…") { session.beginLevels() }
                        .keyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    Button("Hue/Saturation…") { session.beginHueSaturation() }
                        .keyboardShortcut("u").disabled(!session.canAdjustColors)
                    ForEach([FilterKind.exposure, .gradientMap, .grain], id: \.self) { kind in
                        Button(kind.rawValue.localized + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                    Button((session.isMaskSelected ? "Invert Mask" : "Invert").localized) { Task { await session.invertPixels() } }
                        .keyboardShortcut("i")
                        .disabled(!session.canInvert)
                    Divider()
                    Button("Canvas Size…") { Task { await applicationDelegate.projects.canvasSize() } }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Button("Image Size…") { Task { await applicationDelegate.projects.imageSize() } }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.document == nil || !applicationDelegate.projects.canStart)
                    Group {
                        Divider()
                        Button("Flip Canvas Horizontal") { session.flipCanvas(horizontally: true) }
                            .disabled(!session.canEditLayers)
                        Button("Flip Canvas Vertical") { session.flipCanvas(horizontally: false) }
                            .disabled(!session.canEditLayers)
                    }
                }
                CommandMenu("Filter") {
                    ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                        Button(kind.rawValue.localized + "…") { session.beginFilter(kind) }
                            .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                    }
                }
                CommandMenu("Layer") {
                    Menu("New Adjustment Layer") {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue.localized + "…") { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    Button("Edit Adjustment…") {
                        session.adjustmentEditingID = session.activeLayerID
                    }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
                    Divider()
                    Button((session.canTransformSelection ? "Transform Selection" : "Transform Layer").localized) { session.transformCommand() }
                        .keyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
                    Button((session.selection == nil ? "Duplicate Layer" : "Layer via Copy").localized) { session.layerViaCopy() }
                        .keyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer?.isGroup == false))
                    Divider()
                    Button((session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask").localized) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
                    Divider()
                    Button("Group Selected Layers") { session.groupSelectedLayers() }
                        .keyboardShortcut("g").disabled(!session.canEditLayers)
                    Button("Move Out of Folder") { session.moveActiveLayerOutOfGroup() }
                        .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
                    Button("New Blank Layer") { session.addBlankLayer() }
                        .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
                    Button("Rename Layer…") { session.renamingLayerID = session.activeLayerID }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                    Button((session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer").localized) {
                        if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
                    }.disabled(!session.canEditLayers || session.activeLayer == nil)
                    Divider()
                    Button("Move Layer Up") { session.moveActiveLayer(by: 1) }
                        .keyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
                    Button("Move Layer Down") { session.moveActiveLayer(by: -1) }
                        .keyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
                    Group {
                        Button(session.mergeTitle.localized) { session.mergeLayers() }
                            .keyboardShortcut("e").disabled(!session.canMergeLayers)
                        Divider()
                        Button("Flip Layer Horizontal") { session.flipLayers(horizontally: true) }
                            .disabled(!session.canTransform)
                        Button("Flip Layer Vertical") { session.flipLayers(horizontally: false) }
                            .disabled(!session.canTransform)
                    }
                    Divider()
                    Button((session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer").localized) {
                        session.deleteLayerOrMask()
                    }
                        .disabled(!session.canEditLayers || session.activeLayer == nil)
                }
            }
    }
}
