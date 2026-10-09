import AppKit
import SwiftUI

/// Where a panel opens the first time (or each time, for docked styles).
enum FloatingPanelPlacement: Sendable {
    /// Centered on the canvas, or the last position the user left the panel.
    case automatic
    /// Full height of the main document window, flush against its right edge.
    case dockedToMainWindowRight
}

/// A movable, non-modal panel for tool dialogs: it never dims the editor, opens centered on
/// the canvas the first time, and reopens wherever it was last left (for the app session).
/// The close button reports through `onClose` so callers can treat it as Cancel.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    /// Top-left corners (screen coordinates) per panel, so a panel reopens where it was left.
    private static var positions: [String: NSPoint] = [:]
    let identifier: NSUserInterfaceItemIdentifier
    private let name: String
    var onClose: (() -> Void)?
    private var panel: NSPanel?
    private var dismissing = false
    private var placement: FloatingPanelPlacement = .automatic
    private var frameObservers: [NSObjectProtocol] = []
    /// The document window a docked panel is copied from. Kept so a move still tracks that window
    /// after the panel itself has become key.
    private weak var dockedWindow: NSWindow?

    init(name: String) {
        self.name = name
        identifier = NSUserInterfaceItemIdentifier(name)
    }

    func show(title: String, content: some View, placement: FloatingPanelPlacement = .automatic) {
        self.placement = placement
        let panel = self.panel ?? makePanel()
        let wasVisible = panel.isVisible
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.title = localized(title)
        // A hosting *view* sized once, not a controller with `.preferredContentSize`:
        // that option makes AppKit measure the SwiftUI view during its constraint pass,
        // and SwiftUI's measurement invalidates layout re-entrantly, which AppKit treats
        // as a fatal exception.
        let host = NSHostingView(rootView: AnyView(content.roundedControls()))
        // Docked panels fill the window we size. An intrinsic SwiftUI height of zero (a scroll view
        // waiting for a proposed height) must not collapse the content.
        if placement == .dockedToMainWindowRight {
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
        }
        panel.contentView = host
        if placement == .dockedToMainWindowRight {
            applyDockedFrame(panel: panel)
            installFrameObserver(for: panel)
        } else {
            removeFrameObserver()
            let size = host.fittingSize
            if size.width > 0, size.height > 0 { panel.setContentSize(size) }
            if wasVisible {
                panel.setFrameTopLeftPoint(topLeft) // Content changes must not shift the panel.
            } else if let saved = Self.positions[name] {
                panel.setFrameTopLeftPoint(saved)
            } else if let center = (NSApp.mainWindow ?? NSApp.keyWindow).flatMap(Self.canvasCenter) {
                let size = panel.frame.size
                panel.setFrameOrigin(NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
        remember(panel)
    }

    /// Hides the panel without reporting a close.
    func close() {
        guard let panel, panel.isVisible else { return }
        remember(panel)
        removeFrameObserver()
        dismissing = true
        panel.orderOut(nil)
        dismissing = false
    }

    var isVisible: Bool { panel?.isVisible == true }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.identifier = identifier
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// A docked frame is copied from the document window. Remembering it would put the next
    /// Gaussian Blur, and every other filter that shares this panel, on that right edge.
    private func remember(_ panel: NSWindow) {
        guard placement != .dockedToMainWindowRight else { return }
        Self.positions[name] = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// Screen-space center of the editor's canvas area, falling back to the window's.
    static func canvasCenter(in window: NSWindow) -> NSPoint? {
        func find(_ view: NSView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            for child in view.subviews { if let canvas = find(child) { return canvas } }
            return nil
        }
        guard let content = window.contentView else { return nil }
        guard let canvas = find(content) else { return NSPoint(x: window.frame.midX, y: window.frame.midY) }
        let rect = window.convertToScreen(canvas.convert(canvas.bounds, to: nil))
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        if placement != .dockedToMainWindowRight { remember(panel) }
    }

    /// Camera Raw's three grading wheels are the widest thing a docked panel holds; their own
    /// sliders are narrowed to fit this rather than the panel being widened to fit them.
    static let dockedWidth: CGFloat = 440

    private func applyDockedFrame(panel: NSPanel) {
        guard let window = dockedWindow ?? documentWindow() else {
            panel.center()
            return
        }
        let width = Self.dockedWidth
        let frame = window.frame
        let panelFrame = NSRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        panel.setFrame(panelFrame, display: true)
    }

    /// The document window, never the panel itself. A docked panel is key while it is open, and
    /// neither main nor key is set while the app is in the background — so fall back to the
    /// frontmost ordinary window rather than centring the panel somewhere unrelated.
    private func documentWindow() -> NSWindow? {
        if let candidate = NSApp.mainWindow ?? NSApp.keyWindow, candidate !== panel { return candidate }
        return NSApp.windows.first { $0 !== panel && $0.isVisible && !($0 is NSPanel) }
    }

    private func installFrameObserver(for panel: NSPanel) {
        removeFrameObserver()
        guard let window = documentWindow() else { return }
        dockedWindow = window
        let follow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible, self.placement == .dockedToMainWindowRight else { return }
                self.applyDockedFrame(panel: panel)
            }
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main, using: follow))
        }
    }

    private func removeFrameObserver() {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers.removeAll()
        dockedWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let panel { remember(panel) }
        if !dismissing { onClose?() }
    }

    /// Returns keyboard focus to a panel, e.g. after a click on the canvas.
    static func refocus(_ identifier: NSUserInterfaceItemIdentifier) {
        NSApp.windows.first { $0.identifier == identifier && $0.isVisible }?.makeKey()
    }
}
