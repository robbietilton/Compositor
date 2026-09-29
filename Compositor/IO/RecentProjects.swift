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
    private init() {
        refresh()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // A hop rather than `MainActor.assumeIsolated`: the notification handler is a plain C
            // callback as far as the concurrency runtime is concerned, and asserting the actor there
            // read freed executor state and crashed the app when a click activated the window.
            Task { @MainActor in RecentProjects.shared.refresh() }
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
