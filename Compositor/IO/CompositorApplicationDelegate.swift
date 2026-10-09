import AppKit
import Sparkle

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = ProjectWorkspace()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    /// Checks the update feed and installs new versions (Sparkle). Started only after launch: its first-run prompt,
    /// shown during launch, kept the editor window from ever opening.
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var menuTitleObserver: CFRunLoopObserver?

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            if let showEditor { showEditor() }
            // Launched to open a file, SwiftUI makes no window, and the editor that would set `showEditor` never
            // appears. A Dock click's reopen event makes the window, so the app sends itself one once launched.
            else { DispatchQueue.main.async { Self.reopen() } }
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    private static func reopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit's own switches for two of the Edit menu's text extras (see `removeSystemExtras`).
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true, "NSDisabledCharacterPaletteMenuItem": true])
        // Always dark, alerts and open/save panels included, whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS adds Writing Tools, AutoFill, Start Dictation and Emoji & Symbols to the Edit menu; they're for typing
        // text, not editing images, and only got in the way. It adds Enter Full Screen (Globe-F) to the View menu,
        // beside Canvas Only (F), which does the same job without the slow slide into a new space. Taken out once the menus exist, and again whenever the
        // menu bar is opened, in case SwiftUI has rebuilt them since.
        DispatchQueue.main.async { Self.removeSystemExtras() }
        // View › Canvas Only's key is a plain F, and the menu takes a plain letter even while something is being
        // typed. So an F meant for a text field (the palette's search, a layer's name, a number) goes straight to it,
        // before the menu sees it.
        // Escape leaves fullscreen too, once there's nothing in progress for it to cancel first.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  self.session.canvasOnly, self.session.escapeHasNothingToCancel, NSApp.keyWindow === self.projects.window,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self.toggleCanvasOnly()
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "f",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let text = NSApp.keyWindow?.firstResponder as? NSText else { return event }
            text.keyDown(with: event)
            return nil
        }
        // Run as the menu opens (no queue), before it's drawn.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { Self.removeSystemExtras() }
        }
        // Writing Tools and AutoFill are put back each time the Edit menu opens, so they're taken out again as they're
        // added, before the menu is drawn.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
            MainActor.assumeIsolated {
                Self.removeIfSystemExtra(at: index, in: menu)
                Self.normalizeViewMenuTitle()
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didChangeItemNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { Self.normalizeViewMenuTitle() }
        }
        // SwiftUI may restore its system menu title after the item notifications, including in file panels.
        // Normalize once the main run loop finishes that update; only a changed title is written.
        menuTitleObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
                MainActor.assumeIsolated { Self.normalizeViewMenuTitle() }
            }
        if let menuTitleObserver { CFRunLoopAddObserver(CFRunLoopGetMain(), menuTitleObserver, .commonModes) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [updater] in updater.startUpdater() }
    }

    /// Black over everything but the window's inside in Canvas Only: the screen around it, its rounded corners and the
    /// faint rim macOS draws along a window's edge, which no setting takes away.
    private var canvasOnlyFrame: NSWindow?
    /// The window as it was before Canvas Only (F) took the whole screen, to put it back exactly.
    private var windowBeforeCanvasOnly: (frame: NSRect, transparentTitlebar: Bool, titleVisibility: NSWindow.TitleVisibility,
                                         fullSizeContent: Bool, presentation: NSApplication.PresentationOptions)?

    /// Canvas Only: the canvas alone on black over the whole screen, without panels, bars, the menu bar or the Dock;
    /// again, the window as it was. The window covers the screen itself, at once: macOS's own full screen takes a
    /// second and slides the window into a new space.
    func toggleCanvasOnly() {
        guard let window = projects.window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if !session.canvasOnly {
            // Already in macOS full screen, it has the screen; only the panels need putting away.
            if window.styleMask.contains(.fullScreen) { window.toolbar?.isVisible = false }
            if !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main {
                windowBeforeCanvasOnly = (window.frame, window.titlebarAppearsTransparent, window.titleVisibility,
                                          window.styleMask.contains(.fullSizeContentView), NSApp.presentationOptions)
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
                window.toolbar?.isVisible = false
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                buttons.forEach { window.standardWindowButton($0)?.isHidden = true }
                window.setFrame(screen.frame, display: true, animate: false)
                // Over the window, moving with it, letting every click through to the canvas.
                let frame = canvasOnlyFrame ?? NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                frame.isOpaque = false
                frame.backgroundColor = .clear
                frame.isReleasedWhenClosed = false
                frame.ignoresMouseEvents = true
                frame.hasShadow = false
                frame.setFrame(screen.frame, display: false)
                // The window may stop short of the screen's top, kept clear of the menu bar it hides.
                let inside = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).insetBy(dx: 2, dy: 2)
                frame.contentView = CanvasOnlyFrameView(inside: inside)
                window.addChildWindow(frame, ordered: .above)
                canvasOnlyFrame = frame
            }
            session.canvasOnly = true
        } else {
            session.canvasOnly = false
            // In order: the window's title bar as it was, then its toolbar, then its size, so the toolbar lays its
            // buttons out beside the window buttons as it did at launch.
            if let before = windowBeforeCanvasOnly {
                NSApp.presentationOptions = before.presentation
                if !before.fullSizeContent { window.styleMask.remove(.fullSizeContentView) }
                window.titlebarAppearsTransparent = before.transparentTitlebar
                window.titleVisibility = before.titleVisibility
                buttons.forEach { window.standardWindowButton($0)?.isHidden = false }
                window.toolbar?.isVisible = true
                window.setFrame(before.frame, display: true, animate: false)
                if let frame = canvasOnlyFrame {
                    window.removeChildWindow(frame)
                    frame.orderOut(nil)
                }
                windowBeforeCanvasOnly = nil
            } else {
                window.toolbar?.isVisible = true
            }
        }
    }

    /// Takes macOS's extras (text-typing items and Enter Full Screen) out of the menu bar's menus, found by what they do rather than their titles, so
    /// it holds in any language, then tidies the separators they leave behind.
    @MainActor static func removeSystemExtras() {
        normalizeViewMenuTitle()
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            let extras = menu.items.filter(isSystemExtra)
            guard !extras.isEmpty else { continue }
            extras.forEach(menu.removeItem)
            tidySeparators(menu)
        }
    }

    private static var normalizingMenuTitle = false
    /// SwiftUI also refreshes menu titles when editor state changes, without opening a menu.
    @MainActor private static func normalizeViewMenuTitle() {
        guard !normalizingMenuTitle else { return }
        normalizingMenuTitle = true
        defer { normalizingMenuTitle = false }
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu,
                  menu.items.contains(where: { $0.title == localized("Search Commands…") }) else { continue }
            let title = localized("View")
            if top.title != title { top.title = title }
            if menu.title != title { menu.title = title }
        }
    }

    /// One item just added to a menu bar menu: taken out again if it's one of the text extras.
    @MainActor private static func removeIfSystemExtra(at index: Int, in menu: NSMenu) {
        guard menu.supermenu === NSApp.mainMenu, menu.items.indices.contains(index), isSystemExtra(menu.items[index]) else { return }
        menu.removeItem(at: index)
        tidySeparators(menu)
    }

    private static func isSystemExtra(_ item: NSMenuItem) -> Bool {
        let actions: Set<String> = ["startDictation:", "orderFrontCharacterPalette:", "toggleFullScreen:"]
        let identifiers: Set<String> = ["__NSTextViewContextSubmenuIdentifierWritingTools", "_NSMenuItemAutoFillIdentifier",
                                        "_NSMenuItemLegacyWritingToolsSeparatorIdentifier"]
        return item.identifier.map { identifiers.contains($0.rawValue) } == true
            || item.action.map { actions.contains(NSStringFromSelector($0)) } == true
    }

    /// No separator left at the end of a menu, or two in a row.
    private static func tidySeparators(_ menu: NSMenu) {
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        for index in stride(from: menu.items.count - 1, to: 0, by: -1)
        where menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
            menu.removeItem(at: index)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // What's still open (a dialog, a gradient waiting for Apply) is settled by confirmQuit, which beeps if
        // something, a save still running say, has to finish first.
        guard !workspace.isManaging else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.confirmQuit()) }
        return .terminateLater
    }
}

/// Canvas Only's black surround: everything black but `inside`, the window's interior with its corners rounded off.
private final class CanvasOnlyFrameView: NSView {
    private let inside: NSRect
    init(inside: NSRect) {
        self.inside = inside
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let path = NSBezierPath(rect: bounds)
        // Rounder than the window's own corners, so the black reaches into them: past a window's rounded corner
        // there is nothing, and the screen behind showed through.
        path.append(NSBezierPath(roundedRect: inside, xRadius: 26, yRadius: 26))
        path.windingRule = .evenOdd
        path.fill()
    }
}
