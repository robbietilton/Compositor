import AppKit
import Sparkle
import SwiftUI

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    private var editorWindow: NSWindow? {
        NSApp.windows.first { window in
            window.level == .normal && window.styleMask.contains(.titled)
        }
    }
    private var settingsWindow: NSWindow?

    func showEditorWindow() {
        if let window = editorWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Checks the update feed and installs new versions (Sparkle). Started only after launch: its first-run prompt,
    /// shown during launch, kept the editor window from ever opening.
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if editorWindow?.isVisible != true {
            showEditor?()
        }
        application.activate(ignoringOtherApps: true)
        Task { await workspace.receive(urls) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [updater] in updater.startUpdater() }
    }

    @MainActor
    func showSettings(languageStore: AppLanguageStore) {
        let rootView = SettingsWindowRoot(languageStore: languageStore)
        if let settingsWindow {
            settingsWindow.contentViewController = NSHostingController(rootView: rootView)
            settingsWindow.title = L10n.text("settings.open", locale: languageStore.locale)
            settingsWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = NSHostingController(rootView: rootView)
            window.title = L10n.text("settings.open", locale: languageStore.locale)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.canSwitch else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.confirmQuit()) }
        return .terminateLater
    }
}
