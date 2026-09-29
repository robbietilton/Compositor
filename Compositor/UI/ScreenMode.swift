import AppKit
import Observation

/// Photoshop's three screen modes, which F steps through.
enum ScreenMode: CaseIterable {
    /// The window as the person sized it.
    case standard
    /// The window fills the screen's visible area, menu bar and Dock left showing, without its toolbar.
    case fullScreenWithMenuBar
    /// macOS full screen. Tools and panels stay, as in Photoshop; Shift-Tab hides them.
    case fullScreen

    var next: ScreenMode {
        switch self {
        case .standard: .fullScreenWithMenuBar
        case .fullScreenWithMenuBar: .fullScreen
        case .fullScreen: .standard
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard Screen Mode"
        case .fullScreenWithMenuBar: "Full Screen Mode with Menu Bar"
        case .fullScreen: "Full Screen Mode"
        }
    }
}

/// What screen modes need from the editor window: its frame, the screen area it can fill, full screen and the
/// toolbar. NSWindow provides it; tests use a stand-in.
@MainActor protocol ScreenModeWindow: AnyObject {
    var frame: NSRect { get }
    /// The screen's area outside the menu bar and Dock, nil when the window isn't on a screen.
    var fillFrame: NSRect? { get }
    var isInFullScreen: Bool { get }
    var showsToolbar: Bool { get set }
    func setFrame(_ frame: NSRect, display: Bool)
    func toggleFullScreen(_ sender: Any?)
}

extension NSWindow: ScreenModeWindow {
    var fillFrame: NSRect? { (screen ?? NSScreen.main)?.visibleFrame }
    var isInFullScreen: Bool { styleMask.contains(.fullScreen) }
    var showsToolbar: Bool {
        get { toolbar?.isVisible ?? true }
        set { toolbar?.isVisible = newValue }
    }
}

/// The editor window's screen mode, and whether its panels show. One per app: Compositor has one editor window,
/// whose projects are tabs.
@MainActor @Observable
final class ScreenModeController {
    static let shared = ScreenModeController()

    private(set) var mode: ScreenMode = .standard
    /// Shift-Tab: the tool bar, tool options, Layers panel and status bar. For the session only, never saved, so a
    /// relaunch always brings them back.
    var showsPanels = true

    @ObservationIgnored private weak var window: ScreenModeWindow?
    /// Where the window was in Standard, to go back there.
    @ObservationIgnored private var standardFrame: NSRect?
    /// The mode to take once macOS has finished leaving full screen.
    @ObservationIgnored private var afterExit: ScreenMode?
    /// macOS is animating into or out of full screen; mode changes wait until it's done.
    @ObservationIgnored private var transitioning = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {}

    func attach(_ window: ScreenModeWindow) {
        guard self.window !== window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window = window as? NSWindow else { return }
        let center = NotificationCenter.default
        // Made once on the main actor, so the callbacks below only hop there.
        let entered: @MainActor @Sendable () -> Void = { [weak self] in self?.windowDidEnterFullScreen() }
        let exited: @MainActor @Sendable () -> Void = { [weak self] in self?.windowDidExitFullScreen() }
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                Task { @MainActor in entered() }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                Task { @MainActor in exited() }
            },
        ]
    }

    func cycle() { set(mode.next) }

    func set(_ target: ScreenMode) {
        guard let window, target != mode, !transitioning else { return }
        if mode == .standard { standardFrame = window.frame }
        switch target {
        case .fullScreen:
            window.showsToolbar = false
            mode = .fullScreen
            if !window.isInFullScreen {
                transitioning = true
                window.toggleFullScreen(nil)
            }
        case .standard, .fullScreenWithMenuBar:
            if window.isInFullScreen {
                afterExit = target
                transitioning = true
                window.toggleFullScreen(nil)
            } else {
                apply(target, to: window)
            }
        }
    }

    /// macOS finished entering full screen, whether F asked for it or the green button did.
    func windowDidEnterFullScreen() {
        transitioning = false
        guard let window, mode != .fullScreen else { return }
        window.showsToolbar = false
        mode = .fullScreen
    }

    /// macOS finished leaving full screen: the mode F asked for, or Standard when it left another way. macOS has
    /// already put the window back where it was before full screen.
    func windowDidExitFullScreen() {
        transitioning = false
        guard let window else { return }
        let target = afterExit ?? .standard
        afterExit = nil
        apply(target, to: window)
    }

    private func apply(_ target: ScreenMode, to window: ScreenModeWindow) {
        switch target {
        case .standard:
            // Showing the toolbar changes the window's height, so the frame to keep is taken first and put back after:
            // Standard's own, or, back from a full screen the green button started, the one macOS just restored.
            let restore = standardFrame ?? window.frame
            window.showsToolbar = true
            window.setFrame(restore, display: true)
            standardFrame = nil
        case .fullScreenWithMenuBar:
            window.showsToolbar = false
            if let fill = window.fillFrame { window.setFrame(fill, display: true) }
        case .fullScreen:
            break
        }
        mode = target
    }
}
