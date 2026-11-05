import Testing
import UIKit
@testable import Compositor

/// Who draws: fingers, until Apple Pencil turns up, then as the toolbar's item says, with the pressure of a Pencil that
/// reports it in Pressure Sensitivity; and how the item and the status line show it.
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

    /// A window following `input`, loaded and up to date, and its item for who draws.
    private func window(_ input: DrawingInput) throws -> (EditorWindowController, UIBarButtonItem) {
        let window = EditorWindowController()
        window.input = input
        window.loadViewIfNeeded()
        window.updatePropertiesIfNeeded()
        return (window, try #require(window.navigationItem.trailingItemGroups.first?.barButtonItems.first))
    }

    private func update(_ window: EditorWindowController) {
        window.setNeedsUpdateProperties()
        window.updatePropertiesIfNeeded()
    }

    // MARK: Who draws

    /// Fingers draw until Apple Pencil turns up; then only it draws, unless the switch says fingers too. The switch is
    /// kept for the next launch, which starts without a Pencil again. A Pencil that doesn't report its force never
    /// brings its pressure.
    @Test func fingersDrawUntilApplePencilTurnsUp() throws {
        let defaults = try defaults()
        let input = DrawingInput(defaults: defaults)
        #expect(input.fingerPaints && !input.hasPencil && input.mode == .pencil && !input.followsPressure)
        #expect(input.pencilTurnedUp() == .pencil)
        #expect(!input.fingerPaints && input.hasPencil && !input.hasPressure && !input.followsPressure)
        #expect(input.pencilTurnedUp() == nil)
        input.mode = .finger
        #expect(input.fingerPaints && !input.followsPressure)

        let relaunched = DrawingInput(defaults: defaults)
        #expect(relaunched.fingerPaints && !relaunched.hasPencil && relaunched.mode == .finger)
        // Left with fingers drawing too, Apple Pencil turning up takes nothing from them.
        #expect(relaunched.pencilTurnedUp() == nil)
        #expect(relaunched.fingerPaints && relaunched.hasPencil && relaunched.modes == [.pencil, .finger])
    }

    /// An Apple Pencil's first touch reporting its force brings Pressure Sensitivity, unless fingers were left drawing
    /// too, and that touch already has it; the pressure reaches the brush only in it.
    @Test func applePencilsPressureComesInPressureSensitivity() throws {
        for (saved, hover) in [(true, false), (false, false), (true, true), (false, true)] {
            let defaults = try defaults()
            defaults.set(saved, forKey: "pencilOnly")
            let input = DrawingInput(defaults: defaults)
            if hover {
                // Hovering, or a tap on the Pencil, doesn't say whether it reports its force: a plain Pencil until it
                // touches.
                input.pencilTurnedUp()
                #expect(input.hasPencil && !input.hasPressure && !input.followsPressure && input.modes == [.pencil, .finger])
            }
            if saved {
                #expect(input.pencilTurnedUp(pressure: true) == .pressure, "\(hover)")
                #expect(input.mode == .pressure && input.followsPressure && !input.fingerPaints && input.hasPressure)
            } else {
                // Left with fingers drawing too, the pressure only becomes there to choose.
                #expect(input.pencilTurnedUp(pressure: true) == nil, "\(hover)")
                #expect(input.mode == .finger && !input.followsPressure && input.fingerPaints && input.hasPressure)
                input.mode = .pressure
            }
            #expect(input.modes == [.pressure, .pencil, .finger])
            #expect(input.pencilTurnedUp(pressure: true) == nil && input.pencilTurnedUp() == nil)

            input.mode = .pencil
            #expect(!input.followsPressure && !input.fingerPaints)
            input.mode = .finger
            #expect(!input.followsPressure && input.fingerPaints)
            #expect(input.pencilTurnedUp(pressure: true) == nil && input.mode == .finger, "chosen since, it stays")
            input.mode = .pressure
            #expect(input.followsPressure)
        }
    }

    /// Each launch's first touch of a Pencil that reports its force brings Pressure Sensitivity back, unless fingers
    /// were left drawing too, which the Pencil turning up doesn't take from them. The rule is in one place, to change
    /// on its own.
    @Test func pressureSensitivityComesBackAtEachLaunch() throws {
        #expect(DrawingInput.modeOnPressure(from: .pencil) == .pressure)
        #expect(DrawingInput.modeOnPressure(from: .finger) == .finger)
        #expect(DrawingInput.modeOnPressure(from: .pressure) == .pressure)

        let defaults = try defaults()
        for chosen in [DrawingInput.Mode.pencil, .finger] {
            let input = DrawingInput(defaults: defaults)
            input.pencilTurnedUp(pressure: true)
            input.mode = chosen
            let relaunched = DrawingInput(defaults: defaults)
            #expect(relaunched.mode == chosen && !relaunched.followsPressure)
            let changed = relaunched.pencilTurnedUp(pressure: true)
            if chosen == .pencil {
                #expect(changed == .pressure && relaunched.followsPressure)
            } else {
                #expect(changed == nil && relaunched.mode == .finger && !relaunched.followsPressure && relaunched.fingerPaints)
            }
        }
    }

    /// The canvas hands the brush Apple Pencil's pressure only in Pressure Sensitivity; in the other modes it paints at
    /// full pressure, as a finger does.
    @Test func onlyPressureSensitivityHandsTheBrushThePressure() throws {
        func pressure(_ follows: Bool, type: UITouch.TouchType = .pencil) -> CGFloat? {
            PadCanvasView.pressure(type: type, force: 1, maximumPossibleForce: 4.167, followsPressure: follows)
        }
        #expect(pressure(true) == PadCanvasInput.pressure(type: .pencil, force: 1, maximumPossibleForce: 4.167))
        #expect(pressure(true) != nil)
        #expect(pressure(false) == nil)
        #expect(pressure(true, type: .direct) == nil)
    }

    /// The window's canvas follows at once: the touch that showed the Pencil reports its force paints with it, before
    /// the window's next update; and switching away from Pressure Sensitivity takes it from the canvas.
    @Test func theFirstTouchReportingForceAlreadyHasThePressure() throws {
        let input = DrawingInput(defaults: try defaults())
        let (window, _) = try window(input)
        let canvas = try #require(window.activeTab?.canvas)
        #expect(!canvas.followsPressure)
        canvas.pencilSeen(true)
        #expect(canvas.followsPressure && !canvas.fingerPaints)
        window.chooseInput(.pencil)
        update(window)
        #expect(!canvas.followsPressure && !canvas.fingerPaints)
        window.chooseInput(.finger)
        update(window)
        #expect(!canvas.followsPressure && canvas.fingerPaints)
        window.chooseInput(.pressure)
        update(window)
        #expect(canvas.followsPressure)
    }

    // MARK: The toolbar

    /// The switch for who draws sits in the toolbar just before Undo and Redo, there only once Apple Pencil turns up.
    /// With a Pencil that doesn't report its force, a tap flips it between Apple Pencil alone and fingers too, each
    /// with its symbol and color.
    @Test func theSwitchSitsBesideUndoOnceApplePencilTurnsUp() throws {
        let input = DrawingInput(defaults: try defaults())
        let (window, item) = try window(input)
        let groups = window.navigationItem.trailingItemGroups
        #expect(groups.count > 1 && groups[1].barButtonItems.map(\.accessibilityLabel) == ["Undo", "Redo"])
        #expect(item.isHidden)

        input.pencilTurnedUp()
        update(window)
        #expect(!item.isHidden && item.menu == nil && item.primaryAction != nil)
        #expect(item.accessibilityLabel == "Pencil" && item.accessibilityValue == "Draw with Apple Pencil only")
        #expect(item.image == UIImage(systemName: "pencil") && item.tintColor == .systemBlue)
        window.switchInput()
        update(window)
        #expect(input.mode == .finger)
        #expect(item.accessibilityLabel == "Finger Touch" && item.accessibilityValue == "Draw with fingers and Apple Pencil")
        #expect(item.image == UIImage(systemName: "hand.tap") && item.tintColor == nil)
        window.switchInput()
        update(window)
        #expect(input.mode == .pencil && item.tintColor == .systemBlue)
    }

    /// With a Pencil that reports its force, the item is a menu of the three, each with its symbol and the one in use
    /// checked, and the item takes the mode's symbol and color.
    @Test func aPencilReportingForceMakesTheSwitchAMenu() throws {
        let input = DrawingInput(defaults: try defaults())
        let (window, item) = try window(input)
        input.pencilTurnedUp()
        update(window)
        #expect(item.menu == nil)

        input.pencilTurnedUp(pressure: true)
        update(window)
        #expect(!item.isHidden && item.primaryAction == nil)
        let menu = try #require(item.menu)
        let actions = menu.children.compactMap { $0 as? UIAction }
        #expect(actions.count == 3 && menu.children.count == 3)
        #expect(actions.map(\.title) == ["Pressure Sensitivity", "Pencil", "Finger Touch"])
        #expect(actions.map(\.image) == ["pencil.and.scribble", "pencil", "hand.tap"].map { UIImage(systemName: $0) })
        #expect(actions.map(\.state) == [.on, .off, .off])
        #expect(item.image == UIImage(systemName: "pencil.and.scribble") && item.tintColor == .systemPurple)
        #expect(item.accessibilityLabel == "Pressure Sensitivity")
        #expect(item.accessibilityValue == "Draw with Apple Pencil only · Its pressure sets the brush")

        for (index, mode) in [(1, DrawingInput.Mode.pencil), (2, .finger), (0, .pressure)] {
            window.chooseInput(mode)
            update(window)
            #expect(input.mode == mode)
            let states = try #require(item.menu).children.compactMap { ($0 as? UIAction)?.state }
            #expect(states == (0..<3).map { $0 == index ? .on : .off }, "\(mode)")
            #expect(item.image == UIImage(systemName: DrawingInput.symbol(of: mode)))
            #expect(item.tintColor == DrawingInput.tint(of: mode))
        }
    }

    /// Each mode's name, symbol and color, the symbols iPadOS has.
    @Test func eachModeHasItsNameSymbolAndColor() throws {
        let modes = DrawingInput.Mode.allCases
        #expect(modes == [.pressure, .pencil, .finger])
        #expect(modes.map(DrawingInput.title) == ["Pressure Sensitivity", "Pencil", "Finger Touch"])
        #expect(modes.map(DrawingInput.symbol) == ["pencil.and.scribble", "pencil", "hand.tap"])
        #expect(modes.map(DrawingInput.tint) == [.systemPurple, .systemBlue, nil])
        for mode in modes { #expect(UIImage(systemName: DrawingInput.symbol(of: mode)) != nil, "\(mode)") }
    }

    // MARK: The status line

    /// Each mode said whole, as it holds on its own; with a Pencil that reports its force, whether the pressure counts.
    @Test func eachModeIsSaidWhole() throws {
        #expect(DrawingInput.description(of: .pressure, hasPressure: true) == "Draw with Apple Pencil only · Its pressure sets the brush")
        #expect(DrawingInput.description(of: .pencil, hasPressure: true) == "Draw with Apple Pencil only · Every stroke at full pressure")
        #expect(DrawingInput.description(of: .finger, hasPressure: true) == "Draw with fingers and Apple Pencil · Every stroke at full pressure")
        #expect(DrawingInput.description(of: .pencil, hasPressure: false) == "Draw with Apple Pencil only")
        #expect(DrawingInput.description(of: .finger, hasPressure: false) == "Draw with fingers and Apple Pencil")
    }

    /// The status line says the mode whole as it changes: as Apple Pencil takes drawing from fingers, as its pressure
    /// comes in, and as the item changes it.
    @Test func theStatusLineSaysEachNewMode() throws {
        let input = DrawingInput(defaults: try defaults())
        let (window, _) = try window(input)
        let bar = try #require(views(StatusBarView.self, in: window.view).first)
        let canvas = try #require(window.activeTab?.canvas)
        canvas.pencilSeen(false)
        #expect(bar.flashed == "Draw with Apple Pencil only")
        canvas.pencilSeen(true)
        #expect(bar.flashed == "Draw with Apple Pencil only · Its pressure sets the brush")
        window.chooseInput(.finger)
        #expect(bar.flashed == "Draw with fingers and Apple Pencil · Every stroke at full pressure")
        window.chooseInput(.pencil)
        #expect(bar.flashed == "Draw with Apple Pencil only · Every stroke at full pressure")
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
