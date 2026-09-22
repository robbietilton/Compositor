import AppKit

/// Handles document commands at the canvas responder boundary.
///
/// SwiftUI's `CommandGroup` still supplies the menu items and their visible key equivalents, but on older
/// macOS releases a key event can reach the custom `CanvasView` without invoking the SwiftUI command. Keeping
/// this routing next to the canvas also lets text fields retain native Command-C/V/Z behavior.
@MainActor
final class EditorCommandRouter {
    private let session: EditorSession

    init(session: EditorSession) {
        self.session = session
    }

    @discardableResult
    func handle(_ event: NSEvent, firstResponder: NSResponder? = nil) -> Bool {
        let responder = firstResponder ?? NSApp.keyWindow?.firstResponder
        guard let title = ShortcutSettings.shared.menuTitle(for: event) else { return false }

        // On the welcome canvas an image paste intentionally wins over a focused width/height field, matching
        // the menu command and Photoshop's Cmd-N/Cmd-V workflow. Once a document exists, text controls keep native
        // paste below.
        if title == "Paste", session.canPasteIntoNewCanvas {
            session.paste()
            return true
        }
        guard !Self.isTextEditingResponder(responder) else { return false }

        switch title {
        case "Deselect":
            guard session.selection != nil, session.canEditSelection else { return false }
            session.deselect()
            return true
        case "Undo":
            guard session.canUndo else { return false }
            session.undo()
            return true
        case "Redo":
            guard session.canRedo else { return false }
            session.redo()
            return true
        case "Copy":
            guard session.canCopyPixels else { return false }
            session.copySelection()
            return true
        case "Paste":
            guard session.canPaste else { return false }
            session.paste()
            return true
        default:
            return false
        }
    }

    /// NSText is also the field editor used by SwiftUI controls. Do not steal editing commands from it.
    static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField || responder is NSSearchField || responder is NSComboBox
    }
}
