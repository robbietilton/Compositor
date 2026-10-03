import CoreGraphics
import Testing
import UIKit
@testable import Compositor

/// Modifier keys held on a hardware keyboard, before a touch or the pointer moves: what they change shows at once, as
/// on the Mac.
@MainActor struct PadHeldKeyTests {
    /// A window on the app's screen showing a 400 × 300 project of one gray layer, fitted, with `tool`, once it has
    /// appeared and taken the keyboard.
    private func window(_ tool: NavigationTool) async throws -> (controller: EditorWindowController, tab: EditorTab, window: UIWindow) {
        let controller = EditorWindowController()
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<250 where !controller.isFirstResponder { try await Task.sleep(for: .milliseconds(20)) }
        let tab = try #require(controller.activeTab)
        let session = tab.session
        session.createNewProject(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(tool)
        return (controller, tab, window)
    }

    /// A 400 × 300 canvas of one gray layer fitted to a view its size, with `tool`.
    private func session(_ tool: NavigationTool) throws -> EditorSession {
        let session = EditorSession()
        session.viewport.resize(to: CGSize(width: 400, height: 300), backingScale: 1, documentSize: nil)
        session.createDocument(width: 400, height: 300)
        let context = try BrushRaster.context(width: 400, height: 300, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        session.selectTool(tool)
        return session
    }

    /// The canvas point over document pixel (`x`, `y`).
    private func point(_ x: CGFloat, _ y: CGFloat, in session: EditorSession) -> CGPoint {
        session.viewport.viewPoint(from: CGPoint(x: x, y: y), documentSize: CGSize(width: 400, height: 300))
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    // MARK: The selection's mode

    /// Shift shows Add and Option Subtract in the selection tools' bar as they're held, as on the Mac; let go, the mode
    /// chosen shows again.
    @Test func heldKeysShowTheSelectionMode() async throws {
        let (controller, tab, window) = try await window(.marquee)
        defer { window.isHidden = true }
        let session = tab.session
        session.selectAll()
        try #require(session.displayedSelectionMode == .replace)
        controller.holdKeys(.shift)
        #expect(session.displayedSelectionMode == .add)
        controller.holdKeys([.shift, .alternate])
        #expect(session.displayedSelectionMode == .subtract)
        controller.holdKeys([])
        #expect(session.displayedSelectionMode == .replace)
    }

    /// Keys go when they're cancelled, or the app goes to the background or the switcher.
    @Test func heldKeysGoWithTheKeyboard() async throws {
        let (controller, tab, window) = try await window(.marquee)
        defer { window.isHidden = true }
        let session = tab.session
        controller.holdKeys(.shift)
        try #require(session.displayedSelectionMode == .add)
        controller.pressesCancelled([], with: nil)
        #expect(controller.heldKeys.isEmpty && session.displayedSelectionMode == .replace)
        controller.holdKeys(.alternate)
        try #require(session.displayedSelectionMode == .subtract)
        controller.releaseKeys()
        #expect(controller.heldKeys.isEmpty && session.displayedSelectionMode == .replace)
    }

    /// Keys held while typing in a field don't count, as on the Mac: ⌘A there shouldn't flicker the bar.
    @Test func keysHeldWhileTypingDontCount() async throws {
        let (controller, tab, window) = try await window(.marquee)
        defer { window.isHidden = true }
        let field = UITextField()
        controller.view.addSubview(field)
        defer { field.removeFromSuperview() }
        try #require(field.becomeFirstResponder())
        controller.holdKeys(.shift)
        #expect(controller.heldKeys.isEmpty && tab.session.displayedSelectionMode == .replace)
    }

    /// A touch or the pointer reports the keys held with it, which corrects what the window holds, as the Mac's canvas
    /// reads them again at each mouse event.
    @Test func theCanvasReportsTheKeysItSees() async throws {
        let (controller, tab, window) = try await window(.marquee)
        defer { window.isHidden = true }
        tab.canvas.hover(at: CGPoint(x: 200, y: 150), keys: .shift)
        #expect(controller.heldKeys == .shift)
        tab.canvas.hover(at: CGPoint(x: 210, y: 150), keys: [])
        #expect(controller.heldKeys.isEmpty)
    }

    // MARK: The Move tool's bar

    /// Command shows Auto Select turned the other way while it's held, and Shift the aspect-ratio lock, as on the Mac;
    /// turned while a key is held, they're kept as the Mac keeps them.
    @Test func heldKeysFlipAutoSelectAndTheLock() throws {
        let session = try session(.move)
        let bar = ToolOptionsBar(frame: CGRect(x: 0, y: 0, width: 1100, height: ToolOptionsBar.height))
        bar.session = session
        bar.updatePropertiesIfNeeded()
        let autoSelect = try #require(views(UIButton.self, in: bar).first { $0.configuration?.title == "Auto Select" })
        let lock = try #require(views(UIButton.self, in: bar).first { $0.accessibilityLabel == "Lock aspect ratio" })
        let autoSelects = session.transformAutoSelect, locks = session.locksTransformRatio
        #expect(autoSelect.isSelected == autoSelects && lock.isSelected == locks)

        bar.heldKeys = .command
        bar.updatePropertiesIfNeeded()
        #expect(autoSelect.isSelected == !autoSelects && lock.isSelected == locks)
        bar.heldKeys = .shift
        bar.updatePropertiesIfNeeded()
        #expect(autoSelect.isSelected == autoSelects && lock.isSelected == !locks)

        // Shown off with Command held and turned on, as on the Mac the box keeps what it shows less the key.
        bar.heldKeys = .command
        bar.updatePropertiesIfNeeded()
        autoSelect.isSelected.toggle()
        autoSelect.sendActions(for: .primaryActionTriggered)
        #expect(session.transformAutoSelect == (autoSelect.isSelected != true))
        bar.heldKeys = []
        bar.updatePropertiesIfNeeded()
        #expect(autoSelect.isSelected == session.transformAutoSelect)
    }

    // MARK: The brush cursor

    /// Option shows Clone Stamp's crosshair, which sets its source, and takes the Brush's circle away, which samples a
    /// color, as soon as it's held, with the pointer still.
    @Test func optionChangesTheBrushCursorAtOnce() throws {
        let session = try session(.cloneStamp)
        let canvas = PadCanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        session.brushSettings.diameter = 30
        session.setCloneSource(CGPoint(x: 200, y: 150))
        let at = point(100, 100, in: session)
        canvas.hover(at: at)
        #expect(canvas.overlayView.brushCursor?.crosshair == false)
        canvas.keysChanged(.alternate)
        #expect(canvas.overlayView.brushCursor?.crosshair == true)
        canvas.keysChanged([])
        #expect(canvas.overlayView.brushCursor?.crosshair == false)

        session.selectTool(.brush)
        canvas.synchronizeBrushCursor()
        #expect(canvas.overlayView.brushCursor != nil)
        canvas.keysChanged(.alternate)
        #expect(canvas.overlayView.brushCursor == nil)
        canvas.keysChanged([])
        #expect(canvas.overlayView.brushCursor != nil)
    }

    // MARK: Drags

    /// A Marquee drag squares as Shift goes down, without waiting for the touch to move, as on the Mac.
    @Test func aMarqueeSquaresAsShiftGoesDown() throws {
        let session = try session(.marquee)
        session.marqueeKind = .rectangle
        let input = PadCanvasInput(session: session)
        input.began(at: point(50, 40, in: session), keys: .control)
        input.moved(to: point(150, 100, in: session), keys: .control)
        let drawn = try #require(session.lassoDraft?.points)
        let box = drawn.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        #expect(box.width == 100 && box.height == 60)
        input.keysChanged([.control, .shift])
        let squared = try #require(session.lassoDraft?.points).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        #expect(squared.width == squared.height)
        input.keysChanged(.control)
        let back = try #require(session.lassoDraft?.points).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        #expect(back.width == 100 && back.height == 60)
        input.cancelled()
    }

    /// A crop drag keeps its middle where it started as Option goes down, as on the Mac.
    @Test func aCropCentersAsOptionGoesDown() throws {
        let session = try session(.crop)
        let input = PadCanvasInput(session: session)
        input.began(at: point(100, 100, in: session), keys: .control)
        input.moved(to: point(200, 150, in: session), keys: .control)
        #expect(session.cropRect == CGRect(x: 100, y: 100, width: 100, height: 50))
        input.keysChanged([.control, .alternate])
        let centered = try #require(session.cropRect)
        #expect(abs(centered.midX - 100) < 0.5 && abs(centered.midY - 100) < 0.5)
        input.cancelled()
    }

    /// Keys held go when another tab comes in front: the canvas that had them leaves the window, and one let up there
    /// never reaches it.
    @Test func heldKeysGoWhenTheTabChanges() async throws {
        let (controller, tab, window) = try await window(.marquee)
        defer { window.isHidden = true }
        controller.holdKeys(.shift)
        try #require(tab.session.displayedSelectionMode == .add)
        controller.newCanvasTab(nil)
        #expect(controller.activeTab !== tab)
        #expect(controller.heldKeys.isEmpty && tab.session.displayedSelectionMode == .replace)
    }

    /// A modifier key let up while the same one on the other side of the keyboard stays down stays held, as on the
    /// Mac.
    @Test func eitherSideHoldsAModifier() {
        var down: Set<UIKeyboardHIDUsage> = []
        var held = EditorWindowController.heldKeys([], changing: [.keyboardLeftShift], down: true, keysDown: &down)
        #expect(held == .shift)
        held = EditorWindowController.heldKeys(held, changing: [.keyboardRightShift], down: true, keysDown: &down)
        held = EditorWindowController.heldKeys(held, changing: [.keyboardLeftShift], down: false, keysDown: &down)
        #expect(held == .shift)
        held = EditorWindowController.heldKeys(held, changing: [.keyboardRightShift], down: false, keysDown: &down)
        #expect(held.isEmpty)
        // Whatever the event says of the other keys stands.
        held = EditorWindowController.heldKeys(.command, changing: [.keyboardLeftAlt], down: true, keysDown: &down)
        #expect(held == [.command, .alternate])
    }
}
