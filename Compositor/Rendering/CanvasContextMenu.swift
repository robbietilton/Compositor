import AppKit

/// An AppKit menu built out of closures.
///
/// Menu items are target/action, and a menu that names a command where the command lives reads better
/// than a pile of `@objc` methods on the view. The action objects are held by the menu itself, which
/// outlives the click that opened it.
final class ClosureMenu {
    private let menu = NSMenu()

    init() {
        // Every item says for itself whether it applies; leaving AppKit to ask the target would dim
        // items whose state the menu never observes.
        menu.autoenablesItems = false
    }

    var nsMenu: NSMenu { menu }

    @discardableResult
    func add(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off,
             _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = ClosureMenuAction(handler)
        let item = NSMenuItem(title: title.localizedName,
                              action: #selector(ClosureMenuAction.perform(_:)),
                              keyEquivalent: "")
        item.target = action
        // A target is held weakly, so the item keeps its own action (and that action's closure) alive.
        item.representedObject = action
        item.isEnabled = enabled
        item.state = state
        menu.addItem(item)
        return item
    }

    func separator() {
        menu.addItem(.separator())
    }
}

private final class ClosureMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: Any?) {
        handler()
    }
}

/// The canvas right-click menu.
///
/// Photoshop's menu depends on the tool in hand and then offers the commands that act on the picture
/// itself, so it is split the same way here: nothing useful sits behind a trip to the menu bar for a
/// selection, a crop, a fill or a zoom. Brush tools keep right-drag for size and hardness, and show
/// this menu when the press did not become a drag. Built from a session alone so the menu can be
/// exercised without a live canvas.
enum CanvasContextMenu {
    static func menu(for session: EditorSession) -> NSMenu {
        let menu = ClosureMenu()

        switch session.tool {
        case .marquee, .lasso, .wand:
            menu.add("All", enabled: session.document != nil) { session.selectAll() }
            menu.add("Deselect", enabled: session.selection != nil && session.canEditSelection) { session.deselect() }
            menu.add("Inverse", enabled: session.selection != nil && session.canEditSelection) { session.invertSelection() }
            menu.separator()
            menu.add("Feather…", enabled: session.canModifySelection) { session.promptSelectionAmount(.feather) }
            menu.add("Expand…", enabled: session.canModifySelection) { session.promptSelectionAmount(.expand) }
            menu.add("Contract…", enabled: session.canModifySelection) { session.promptSelectionAmount(.contract) }
            menu.separator()
            menu.add("Subject", enabled: session.canSelectSubject) { Task { await session.selectSubject() } }
            menu.add("Color Range…", enabled: session.canSelectColorRange) { session.beginColorRange() }
            menu.add("Layer's Pixels", enabled: session.activeLayer?.asset != nil && session.canEditSelection) {
                if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
            }
            menu.add("Mask's Black Areas", enabled: session.activeLayer?.mask != nil && session.canEditSelection) {
                if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
            }
            menu.separator()
        case .crop:
            menu.add("Apply Crop", enabled: session.cropRect != nil) { Task { await session.commitCrop() } }
            menu.add("Cancel", enabled: session.cropRect != nil) { session.cancelCrop() }
            menu.separator()
        case .type:
            menu.add("Edit Text", enabled: session.activeLayer?.liveText != nil) { session.editActiveText() }
            menu.add("Done", enabled: session.textDraft != nil) { _ = session.finishText() }
            menu.add("Cancel", enabled: session.textDraft != nil) { session.cancelText() }
            menu.separator()
        case .move:
            menu.add("Flip Layer Horizontal", enabled: session.canTransform) { session.flipLayers(horizontally: true) }
            menu.add("Flip Layer Vertical", enabled: session.canTransform) { session.flipLayers(horizontally: false) }
            menu.add(session.canTransformSelection ? "Transform Selection" : "Transform Layer",
                     enabled: session.canTransform || session.canTransformSelection) { session.transformCommand() }
            menu.add("Layer via Copy", enabled: session.canCopyPixels) { session.layerViaCopy() }
            menu.separator()
        case .brush, .spotHealing, .cloneStamp, .blur, .gradient, .shape, .eyedropper, .hand, .zoom, .idle:
            break
        }

        menu.add("Cut", enabled: session.selection != nil && session.canCopyPixels) {
            Task { await session.cutSelection() }
        }
        menu.add("Copy", enabled: session.canCopyPixels || session.canCopyLayer) { session.copySelection() }
        menu.add("Copy Merged", enabled: session.canCopyMerged) { session.copyMergedSelection() }
        menu.add("Paste", enabled: session.canPaste) { session.paste() }
        menu.separator()
        menu.add("Fill with Foreground Color", enabled: session.canEditPixels) {
            Task { await session.fillSelection(with: .foreground) }
        }
        menu.add("Fill with Background Color", enabled: session.canEditPixels) {
            Task { await session.fillSelection(with: .background) }
        }
        menu.add("Clear Selection Pixels", enabled: session.selection != nil && session.canEditPixels) {
            Task { await session.clearSelectedPixels() }
        }
        menu.add("Content-Aware Fill…", enabled: session.canContentAwareFill) { session.beginFilter(.contentAwareFill) }
        menu.add(session.isMaskSelected ? "Invert Mask" : "Invert", enabled: session.canInvert) {
            Task { await session.invertPixels() }
        }
        menu.separator()
        menu.add("Fit Canvas", enabled: session.document != nil) { session.fit() }
        menu.add("Actual Pixels", enabled: session.document != nil) { session.zoom(to: 1) }
        menu.add("Zoom In", enabled: session.document != nil) { session.zoomKeyboard(by: 1) }
        menu.add("Zoom Out", enabled: session.document != nil) { session.zoomKeyboard(by: -1) }
        return menu.nsMenu
    }
}

extension CanvasView {
    func canvasContextMenu() -> NSMenu {
        CanvasContextMenu.menu(for: session)
    }
}
