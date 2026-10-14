import Foundation
import Testing
import UIKit
@testable import Compositor

/// The app menu's About on iPad: the app's icon, name and version, as the Mac's About panel shows them, with where its
/// source is and the license it's under, whose notice goes with every copy.
@MainActor struct PadAboutTests {
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

    /// Chooses About from the app menu, as the menu bar does, and returns its sheet once it's up.
    private func showAbout(in controller: EditorWindowController) async throws -> AboutController {
        let about = #selector(EditorWindowController.showAbout(_:))
        try #require(controller.canPerformAction(about, withSender: nil))
        controller.perform(about, with: nil)
        try await eventually { controller.presentedViewController?.isBeingPresented == false }
        let navigation = try #require(controller.presentedViewController as? UINavigationController)
        let sheet = try #require(navigation.viewControllers.first as? AboutController)
        sheet.view.layoutIfNeeded()
        return sheet
    }

    private func info(_ key: String) throws -> String {
        try #require(Bundle.main.object(forInfoDictionaryKey: key) as? String, "\(key)")
    }

    /// The app menu begins with About, in the system's place for it, which iPadOS leaves empty; the window answers it
    /// while nothing is over it, as it does the menu bar's other commands that show something.
    @Test func theAppMenuHasAbout() async throws {
        let bar = MenuBarModel.built(by: AppDelegate())
        let app = try #require(bar.bar.submenus.first)
        let group = try #require(app.children.first.flatMap { item -> MenuBarModel.Menu? in
            if case .menu(let menu) = item { menu } else { nil }
        })
        #expect(group.identifier == .about)
        let about = try #require(group.commands.first)
        #expect(group.commands.count == 1)
        #expect(about.title == "About " + (try info("CFBundleDisplayName")))
        #expect(about.action == #selector(EditorWindowController.showAbout(_:)))

        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        #expect(controller.canPerformAction(about.action, withSender: about))
        _ = try await showAbout(in: controller)
        // Not over itself, as no dialog comes over another.
        #expect(!controller.canPerformAction(about.action, withSender: about))
    }

    /// The sheet shows the app's icon, its name and version as the bundle has them, a link to its source, and the whole
    /// license, the bundle's copy, word for word, each paragraph wrapped to the sheet's width. It holds the window on its
    /// tab, as the window's other dialogs do.
    @Test func aboutShowsTheVersionAndLicense() async throws {
        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        let sheet = try await showAbout(in: controller)
        let texts = views(UILabel.self, in: sheet.view).compactMap(\.text)
        #expect(texts.contains(try info("CFBundleDisplayName")))
        #expect(texts.contains("Version \(try info("CFBundleShortVersionString")) (\(try info("CFBundleVersion")))"))
        #expect(views(UIImageView.self, in: sheet.view).contains { $0.image != nil && $0.bounds.width >= 60 })

        let url = try #require(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let license = try String(contentsOf: url, encoding: .utf8)
        let shown = try #require(views(UITextView.self, in: sheet.view).first)
        #expect(license.hasPrefix("MIT License\n\nCopyright (c) 2026 Wonder Assembly LLC\n"))
        #expect(shown.text.split(whereSeparator: \.isWhitespace) == license.split(whereSeparator: \.isWhitespace))
        let paragraphs = shown.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        #expect(paragraphs.count == license.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").count)
        #expect(!paragraphs.contains { $0.contains("\n") })
        #expect(shown.isSelectable && !shown.isEditable && shown.isScrollEnabled)
        #expect(shown.adjustsFontForContentSizeCategory)
        #expect(shown.accessibilityLabel == "License")

        #expect(!controller.canPerformAction(#selector(EditorWindowController.newCanvasTab(_:)), withSender: nil))
    }

    /// The link opens the app's source on GitHub, and says so to VoiceOver.
    @Test func theLinkOpensTheSource() async throws {
        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        let sheet = try await showAbout(in: controller)
        var opened: [URL] = []
        sheet.open = { opened.append($0) }
        let link = try #require(views(UIButton.self, in: sheet.view).first { $0.accessibilityLabel == "Source code on GitHub" })
        #expect(link.accessibilityHint?.isEmpty == false)
        link.sendActions(for: .primaryActionTriggered)
        #expect(opened == [URL(string: "https://github.com/robbietilton/Compositor")!])
    }

    /// Done puts the sheet away, as Escape does, as a dialog's Cancel; the window is free again after.
    @Test(arguments: [true, false])
    func doneOrEscapeClosesIt(done: Bool) async throws {
        let (window, controller) = try await shownWindow()
        defer { close(window, controller) }
        let sheet = try await showAbout(in: controller)
        if done {
            try #require(sheet.navigationItem.rightBarButtonItem?.primaryAction).performWithSender(nil, target: nil)
        } else {
            let escape = try #require(sheet.keyCommands?.first { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
            let action = try #require(escape.action)
            sheet.perform(action, with: escape)
        }
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        try await eventually { controller.canPerformAction(#selector(EditorWindowController.newCanvasTab(_:)), withSender: nil) }
        #expect(controller.canPerformAction(#selector(EditorWindowController.showAbout(_:)), withSender: nil))
    }

    /// The app carries the repository's LICENSE as it is, byte for byte, so the two can't drift apart.
    @Test func theBundledLicenseIsTheRepositorys() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = try #require(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: root.appending(path: "LICENSE")))
    }
}
