import AppKit
import Testing
@testable import Compositor

@MainActor
struct ScreenModeTests {
    /// Stands in for the editor window. macOS's full-screen animation is played by calling the controller's
    /// did-enter / did-exit hooks by hand.
    final class FakeWindow: ScreenModeWindow {
        var frame = NSRect(x: 100, y: 120, width: 900, height: 600)
        var fillFrame: NSRect? = NSRect(x: 0, y: 0, width: 1512, height: 944)
        var isInFullScreen = false
        /// As AppKit does, showing or hiding the toolbar grows or shrinks the window by its height.
        var showsToolbar = true {
            didSet { if showsToolbar != oldValue { frame.size.height += showsToolbar ? 28 : -28 } }
        }
        var toggles = 0
        func setFrame(_ frame: NSRect, display: Bool) { self.frame = frame }
        func toggleFullScreen(_ sender: Any?) { toggles += 1 }
    }

    private func setUp() -> (ScreenModeController, FakeWindow) {
        let controller = ScreenModeController(), window = FakeWindow()
        controller.attach(window)
        return (controller, window)
    }

    /// What macOS does between toggleFullScreen and the did-enter / did-exit notification.
    private func finishEntering(_ controller: ScreenModeController, _ window: FakeWindow) {
        window.isInFullScreen = true
        controller.windowDidEnterFullScreen()
    }
    private func finishExiting(_ controller: ScreenModeController, _ window: FakeWindow) {
        window.isInFullScreen = false
        controller.windowDidExitFullScreen()
    }

    @Test func modesCycleInPhotoshopsOrder() {
        #expect(ScreenMode.standard.next == .fullScreenWithMenuBar)
        #expect(ScreenMode.fullScreenWithMenuBar.next == .fullScreen)
        #expect(ScreenMode.fullScreen.next == .standard)
    }

    @Test func fullCycleEndsWhereItStarted() {
        let (controller, window) = setUp()
        let standard = window.frame
        controller.cycle()
        #expect(controller.mode == .fullScreenWithMenuBar)
        #expect(window.frame == window.fillFrame && !window.showsToolbar)
        controller.cycle()
        #expect(controller.mode == .fullScreen && window.toggles == 1 && !window.showsToolbar)
        finishEntering(controller, window)
        controller.cycle()
        #expect(window.toggles == 2, "asked macOS to leave full screen")
        finishExiting(controller, window)
        #expect(controller.mode == .standard)
        #expect(window.frame == standard && window.showsToolbar)
    }

    @Test func leavingFullScreenAnotherWayReturnsToStandard() {
        let (controller, window) = setUp()
        let standard = window.frame
        controller.set(.fullScreenWithMenuBar)
        controller.set(.fullScreen)
        finishEntering(controller, window)
        finishExiting(controller, window) // the green button, ⌃⌘F or Esc
        #expect(controller.mode == .standard && window.frame == standard && window.showsToolbar)
    }

    @Test func greenButtonFromStandardIsFullScreen() {
        let (controller, window) = setUp()
        let standard = window.frame
        finishEntering(controller, window)
        #expect(controller.mode == .fullScreen && !window.showsToolbar)
        controller.cycle()
        #expect(window.toggles == 1)
        window.frame = standard // macOS puts back the frame it saved on the way in
        finishExiting(controller, window)
        #expect(controller.mode == .standard && window.frame == standard)
    }

    @Test func keysDuringTheAnimationAreIgnored() {
        let (controller, window) = setUp()
        controller.set(.fullScreen)
        controller.cycle()
        controller.set(.fullScreenWithMenuBar)
        #expect(window.toggles == 1 && controller.mode == .fullScreen)
        finishEntering(controller, window)
        controller.cycle()
        #expect(window.toggles == 2)
    }

    @Test func panelsHideInAnyModeAndStartShown() {
        let (controller, _) = setUp()
        #expect(controller.showsPanels)
        controller.showsPanels.toggle()
        controller.cycle()
        #expect(!controller.showsPanels, "switching mode leaves panels as they were")
        #expect(ScreenModeController().showsPanels, "a new session starts with panels")
    }

    @Test func screenModeKeysAreInTheShortcutList() throws {
        let cycle = try #require(ShortcutDefinition.all.first { $0.title == "Cycle screen mode" })
        #expect(cycle.original == ShortcutChord("f") && cycle.group == "Canvas & Layers")
        let panels = try #require(ShortcutDefinition.all.first { $0.title == "Hide or show panels" })
        #expect(panels.original == ShortcutChord("\t", 8))
        #expect(ShortcutSettings.problem(in: [:]) == nil)
    }

    /// The same steps on a real AppKit window with a toolbar, not the stand-in: it fills the screen's visible area
    /// without its toolbar, then goes back.
    @Test func realWindowFillsTheScreenAndComesBack() throws {
        let window = NSWindow(contentRect: CGRect(x: 120, y: 140, width: 700, height: 500),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "ScreenModeTests")
        // Never shown: a window on screen under the pointer would change the cursor that CursorTests, running in
        // parallel, checks.
        let standard = window.frame
        let fill = try #require(window.fillFrame)
        let controller = ScreenModeController()
        controller.attach(window)
        controller.set(.fullScreenWithMenuBar)
        #expect(window.frame == fill && window.toolbar?.isVisible == false)
        controller.set(.standard)
        #expect(window.frame == standard && window.toolbar?.isVisible == true)
    }

    /// Green button in and out: macOS puts back the frame it saved, and showing the toolbar again mustn't then make
    /// the window a toolbar taller than it was.
    @Test func greenButtonRoundTripKeepsTheWindowsSize() {
        let (controller, window) = setUp()
        let standard = window.frame
        finishEntering(controller, window) // hides the toolbar: the window shrinks by its height
        window.frame = standard            // macOS's own full-screen frame, then its restore on the way out
        finishExiting(controller, window)
        #expect(window.showsToolbar && window.frame == standard)
    }
}
