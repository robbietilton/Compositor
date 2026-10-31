import Foundation
import Testing
import UIKit
@testable import Compositor

/// Importing a RAW file on iPad: the develop dialog, as the Mac's sheet, from Import pressed until the layer is in.
@MainActor struct PadRawImportTests {
    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Waits up to a few seconds for `condition`, as UIKit's transitions finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A window on the app's screen as the app makes one, the editor in a navigation controller whose bar is its toolbar,
    /// once it has appeared.
    private func shownWindow() async throws -> (window: UIWindow, controller: EditorWindowController) {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let controller = EditorWindowController()
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return (window, controller)
    }

    /// Puts away what the window shows, and the window.
    private func close(_ window: UIWindow, _ controller: EditorWindowController) {
        controller.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
    }

    /// The develop dialog over the window, once it's up.
    private func shownDialog(over controller: EditorWindowController) async throws
        -> (navigation: UINavigationController, dialog: RawDevelopController) {
        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let navigation = try #require(controller.presentedViewController as? UINavigationController)
        let dialog = try #require(navigation.viewControllers.first as? RawDevelopController)
        dialog.view.layoutIfNeeded()
        dialog.updatePropertiesIfNeeded()
        return (navigation, dialog)
    }

    /// Whether `view` is on screen: in a window, with nothing hiding it or any view around it.
    private func isShown(_ view: UIView) -> Bool {
        view.window != nil && sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden }
    }

    /// Whether `dialog` says it's importing: an "Importing…" label on screen.
    private func saysImporting(_ dialog: RawDevelopController) -> Bool {
        views(UILabel.self, in: dialog.view).contains { $0.text == "Importing…" && isShown($0) }
    }

    /// Presses `dialog`'s Import or Cancel, as a finger does.
    private func press(import ok: Bool, in dialog: RawDevelopController) throws {
        if ok {
            let item = try #require(dialog.navigationItem.rightBarButtonItem)
            _ = UIApplication.shared.sendAction(try #require(item.action), to: item.target, from: item, for: nil)
        } else {
            try #require(dialog.navigationItem.leftBarButtonItem?.primaryAction).performWithSender(nil, target: nil)
        }
    }

    /// The dialog's controls: the sliders, Reset, Import and Cancel.
    private func controls(of dialog: RawDevelopController) throws -> [(name: String, enabled: Bool)] {
        let sliders = views(UISlider.self, in: dialog.view).map { ($0.accessibilityLabel ?? "Slider", $0.isEnabled) }
        let reset = try #require(views(UIButton.self, in: dialog.view).first { $0.configuration?.title == "Reset" })
        return sliders + [("Reset", reset.isEnabled), ("Import", dialog.navigationItem.rightBarButtonItem?.isEnabled == true),
                          ("Cancel", dialog.navigationItem.leftBarButtonItem?.isEnabled == true)]
    }

    /// Import pressed, the dialog stays up, saying it's importing, until the editor has the full frame developed and
    /// the layer in, as the Mac's sheet does; its sliders and buttons take nothing meanwhile, and it can't be pulled
    /// down. No second dialog comes up in its place, and once the editor is done, the window takes it away.
    @Test func theDialogStaysUpWhileTheFrameDevelops() async throws {
        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        let session = try #require(controller.activeTab?.session)
        // As an import of a RAW file asks; this one can't be developed, so the preview stays empty.
        let url = FileManager.default.temporaryDirectory.appending(path: "PadRawImportTests \(UUID().uuidString).dng")
        try Data("Not a RAW file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asked = Task { await session.developRaw(url) }
        let (navigation, dialog) = try await shownDialog(over: controller)
        // Reset follows the settings, as shot here.
        #expect(try controls(of: dialog).allSatisfy { $0.enabled || $0.name == "Reset" })
        #expect(!saysImporting(dialog))

        try press(import: true, in: dialog)
        // The editor has its settings and is developing the full frame.
        let settings = await asked.value
        #expect(settings != nil && session.rawImporting && session.showsRawDevelop)
        try await eventually { saysImporting(dialog) }
        #expect(saysImporting(dialog))
        let controls = try controls(of: dialog)
        #expect(controls.allSatisfy { !$0.enabled }, "\(controls.filter(\.enabled).map(\.name))")
        #expect(dialog.isModalInPresentation)
        // Long enough for a dialog on its way out to have gone, and for another to have come up in its place.
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController === navigation && !navigation.isBeingDismissed)
        #expect(navigation.presentedViewController == nil)
        #expect(navigation.viewControllers.count == 1)

        // The layer is in (or the develop failed): the editor is done with the dialog.
        session.endRawDevelop()
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController == nil, "nothing comes up in its place")
        #expect(!session.showsRawDevelop && !session.rawImporting)
    }

    /// The window's editors develop a RAW at 8 bits, as before 16-bit layers, where the Mac's develop at 16: a
    /// 48-megapixel frame at 16 bits takes more than the 3 GB iPad Air has to spare (see the window's tabs).
    @Test func theWindowsEditorsDevelopRawAtEightBits() throws {
        #expect(EditorSession().developsRawAtSixteenBits, "the Mac's default")
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        let session = try #require(window.activeTab?.session)
        #expect(!session.developsRawAtSixteenBits)
    }

    /// Cancel takes the dialog down at once, leaving the file out.
    @Test func cancelTakesTheDialogDown() async throws {
        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        let session = try #require(controller.activeTab?.session)
        let url = FileManager.default.temporaryDirectory.appending(path: "PadRawImportTests \(UUID().uuidString).dng")
        try Data("Not a RAW file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asked = Task { await session.developRaw(url) }
        let (_, dialog) = try await shownDialog(over: controller)

        try press(import: false, in: dialog)
        #expect(await asked.value == nil)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil && !session.showsRawDevelop && !session.rawImporting)
    }
}
