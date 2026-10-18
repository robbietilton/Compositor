import Testing
import UIKit
@testable import Compositor

/// Who draws: fingers, until Apple Pencil turns up, then as the toolbar's switch says; and how the switch and the
/// status line show it.
@MainActor struct PadDrawingInputTests {
    /// Settings of the test's own, empty.
    private func defaults() throws -> UserDefaults {
        let name = "PadDrawingInputTests \(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// The views of `type` in `view`, depth first.
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        view.subviews.flatMap { subview -> [T] in ((subview as? T).map { [$0] } ?? []) + views(type, in: subview) }
    }

    /// Fingers draw until Apple Pencil turns up; then only it draws, unless the switch says fingers too. The switch is
    /// kept for the next launch, which starts without a Pencil again.
    @Test func fingersDrawUntilApplePencilTurnsUp() throws {
        let defaults = try defaults()
        let input = DrawingInput(defaults: defaults)
        #expect(input.fingerPaints && !input.hasPencil && input.pencilOnly)
        #expect(input.pencilTurnedUp())
        #expect(!input.fingerPaints && input.hasPencil)
        #expect(!input.pencilTurnedUp())
        input.pencilOnly = false
        #expect(input.fingerPaints)

        let relaunched = DrawingInput(defaults: defaults)
        #expect(relaunched.fingerPaints && !relaunched.hasPencil && !relaunched.pencilOnly)
        // Left with fingers drawing too, Apple Pencil turning up takes nothing from them.
        #expect(!relaunched.pencilTurnedUp())
        #expect(relaunched.fingerPaints && relaunched.hasPencil)
    }

    /// The switch for who draws sits in the toolbar just before Undo and Redo, there only once Apple Pencil turns up. It
    /// says who draws in words that hold on their own, and flipping it changes that.
    @Test func theSwitchSitsBesideUndoOnceApplePencilTurnsUp() throws {
        let input = DrawingInput(defaults: try defaults())
        let window = EditorWindowController()
        window.input = input
        window.loadViewIfNeeded()
        window.updatePropertiesIfNeeded()
        let groups = window.navigationItem.trailingItemGroups
        let item = try #require(groups.first?.barButtonItems.first)
        #expect(groups.count > 1 && groups[1].barButtonItems.map(\.accessibilityLabel) == ["Undo", "Redo"])
        #expect(item.isHidden)

        input.pencilTurnedUp()
        window.setNeedsUpdateProperties()
        window.updatePropertiesIfNeeded()
        #expect(!item.isHidden && item.accessibilityLabel == "Draw with Apple Pencil only")
        window.switchInput()
        window.setNeedsUpdateProperties()
        window.updatePropertiesIfNeeded()
        #expect(!input.pencilOnly && item.accessibilityLabel == "Draw with fingers and Apple Pencil")

        #expect(DrawingInput.symbol(pencilOnly: true) == "applepencil.and.scribble")
        #expect(DrawingInput.symbol(pencilOnly: false) == "hand.tap")
        for pencilOnly in [true, false] { #expect(UIImage(systemName: DrawingInput.symbol(pencilOnly: pencilOnly)) != nil) }
    }

    /// A flash says what changed in the hint's place, in the accent color, and the hint comes back after it.
    @Test func theStatusLineFlashesWhatChanged() async throws {
        let session = EditorSession()
        session.createDocument(width: 64, height: 48)
        let bar = StatusBarView(frame: CGRect(x: 0, y: 0, width: 1000, height: StatusBarView.height))
        bar.session = session
        bar.updatePropertiesIfNeeded()
        let hint = try #require(views(UILabel.self, in: bar).last)
        let usual = try #require(hint.text)

        #expect(StatusBarView.flashDuration == .seconds(3))
        bar.flash("Draw with fingers and Apple Pencil", for: .milliseconds(100))
        #expect(hint.text == "Draw with fingers and Apple Pencil" && hint.textColor != .secondaryLabel)
        try await Task.sleep(for: .milliseconds(500))
        bar.updatePropertiesIfNeeded()
        #expect(hint.text == usual && hint.textColor == .secondaryLabel)
    }
}
