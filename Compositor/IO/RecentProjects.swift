import AppKit
import Observation

/// File > Open Recent. macOS keeps the list (the same one the Dock icon's menu shows); this mirrors it so the
/// menu updates as projects are opened and saved. Projects since moved or deleted are left out, checked again each
/// time you come back to the app (from Finder, say).
@MainActor @Observable
final class RecentProjects {
    static let shared = RecentProjects()
    private(set) var urls: [URL] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    /// True until the launch check has run. An activation before that joins the check instead of starting another.
    @ObservationIgnored private var launchRefreshPending = true
    @ObservationIgnored private var launchRefreshQueued = false
    private init() {
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // A hop rather than `MainActor.assumeIsolated`: the notification handler is a plain C
            // callback as far as the concurrency runtime is concerned, and asserting the actor there
            // read freed executor state and crashed the app when a click activated the window.
            Task { @MainActor in RecentProjects.shared.activate() }
        }
        // This object is created while the menus are built. Checking every recent file here blocks that
        // turn — a missing disk makes `fileExists` stall — before the window can appear. The observer's
        // main queue runs the same check once a window is up.
        scheduleLaunchRefresh()
    }

    private func activate() {
        if launchRefreshPending { scheduleLaunchRefresh() } else { refresh() }
    }

    private func scheduleLaunchRefresh() {
        guard launchRefreshPending, !launchRefreshQueued else { return }
        launchRefreshQueued = true
        OperationQueue.main.addOperation {
            Task { @MainActor in RecentProjects.shared.launchRefresh() }
        }
    }

    private func launchRefresh() {
        launchRefreshQueued = false
        guard launchRefreshPending else { return }
        // Miniaturized still counts: the window was restored, and there is no frame left to wait for.
        guard NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else {
            scheduleLaunchRefresh()
            return
        }
        // Visible on this pass. Scan on the next one, so this pass can draw the window first.
        launchRefreshQueued = true
        OperationQueue.main.addOperation {
            Task { @MainActor in
                let recent = RecentProjects.shared
                recent.launchRefreshQueued = false
                guard recent.launchRefreshPending else { return }
                recent.launchRefreshPending = false
                recent.refresh()
            }
        }
    }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refresh()
    }
    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }
    func refresh() {
        urls = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
