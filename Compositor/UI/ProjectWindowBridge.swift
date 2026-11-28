import AppKit
import SwiftUI

/// Intercepts only close approval and forwards SwiftUI's other window callbacks.
struct ProjectWindowBridge: NSViewRepresentable {
    let controller: ProjectController
    func makeNSView(context: Context) -> ProjectWindowView { ProjectWindowView(controller: controller) }
    func updateNSView(_ view: ProjectWindowView, context: Context) {
        view.update(controller)
        view.window?.representedURL = controller.session.projectURL
        view.window?.isDocumentEdited = controller.session.isModified
        view.window?.titleVisibility = .hidden
    }
}

final class ProjectWindowView: NSView {
    var controller: ProjectController
    private let proxy = ProjectWindowDelegate()
    init(controller: ProjectController) {
        self.controller = controller
        super.init(frame: .zero)
        proxy.controller = controller
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ controller: ProjectController) {
        self.controller = controller
        proxy.controller = controller
        controller.window = window
        controller.workspace?.window = window
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.controller.window = window
            self.controller.workspace?.window = window
            if window.delegate !== self.proxy {
                self.proxy.previous = window.delegate
                window.delegate = self.proxy
            }
            Self.fillScreenOnceForThisBuild(window)
        }
    }

    /// The first launch of each build, a new download or an update, fills the screen (without going full screen), as
    /// `defaultWindowPlacement` does only the very first time; after that macOS reopens the window at the size it was left.
    private static func fillScreenOnceForThisBuild(_ window: NSWindow) {
        let key = "windowFilledScreenForBuild"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard UserDefaults.standard.string(forKey: key) != build, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        UserDefaults.standard.set(build, forKey: key)
        window.setFrame(screen.visibleFrame, display: true)
    }
}

private final class ProjectWindowDelegate: NSObject, NSWindowDelegate {
    weak var previous: NSWindowDelegate?
    weak var controller: ProjectController?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller else { return true }
        Task {
            if let workspace = controller.workspace { await workspace.closeWindow(sender) }
            else { await controller.close(sender) }
        }
        return false
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previous?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
    }
}
