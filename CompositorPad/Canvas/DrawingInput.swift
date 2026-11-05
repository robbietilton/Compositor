import Foundation
import Observation
import UIKit

/// Who draws on the canvas, and with what: fingers, until Apple Pencil turns up, and then as the toolbar's item says.
/// Apple Pencil alone, with fingers moving the canvas, or fingers too; and an Apple Pencil that reports its force draws
/// with its pressure too, in Pressure Sensitivity. iPadOS doesn't tell an app whether a Pencil is paired or connected,
/// only what it does: one turns up when it touches the canvas, hovers over it, or is tapped or squeezed, and each
/// launch starts without one. Only its touch says whether it reports its force, so hovering or a tap on it makes it a
/// plain Pencil until it touches.
@MainActor @Observable final class DrawingInput {
    static let shared = DrawingInput(defaults: .standard)

    /// Who draws, once Apple Pencil has turned up.
    enum Mode: CaseIterable {
        /// Apple Pencil alone, its pressure setting the brush's Size and Opacity as they're set to follow it.
        case pressure
        /// Apple Pencil alone, every stroke at full pressure.
        case pencil
        /// Fingers and Apple Pencil, every stroke at full pressure.
        case finger
    }

    /// Whether Apple Pencil has turned up since launch.
    private(set) var hasPencil = false
    /// Whether it reports its force, as Apple Pencil's touch says: Pressure Sensitivity is there to choose then.
    private(set) var hasPressure = false
    /// Who draws once it has. Apple Pencil alone or fingers too is kept across launches; Pressure Sensitivity comes
    /// back with each launch's first touch of a Pencil that reports its force, unless fingers were left drawing too
    /// (`modeOnPressure`).
    var mode: Mode {
        didSet { defaults.set(mode != .finger, forKey: Self.pencilOnlyKey) }
    }
    /// Whether a finger draws.
    var fingerPaints: Bool { !hasPencil || mode == .finger }
    /// Whether Apple Pencil's pressure reaches the brush.
    var followsPressure: Bool { hasPressure && mode == .pressure }

    @ObservationIgnored private let defaults: UserDefaults
    private static let pencilOnlyKey = "pencilOnly"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        mode = (defaults.object(forKey: Self.pencilOnlyKey) as? Bool ?? true) ? .pencil : .finger
    }

    /// The mode a launch's first touch of an Apple Pencil that reports its force turns `mode` into, whether it was kept
    /// from the last launch or chosen since: Pressure Sensitivity, so the pressure is there from the first stroke,
    /// unless fingers were left drawing too, which the Pencil doesn't take from them.
    static func modeOnPressure(from mode: Mode) -> Mode { mode == .finger ? .finger : .pressure }

    /// Apple Pencil touching, hovering, or tapped or squeezed; `pressure` when it touched reporting its force. The mode
    /// to say in the status line when this changed who draws or whether the pressure reaches the brush: the first time
    /// since launch, when it takes drawing from fingers, and its first touch reporting its force.
    @discardableResult func pencilTurnedUp(pressure: Bool = false) -> Mode? {
        let before = (fingerPaints, followsPressure)
        hasPencil = true
        if pressure, !hasPressure {
            hasPressure = true
            mode = Self.modeOnPressure(from: mode)
        }
        return (fingerPaints, followsPressure) == before ? nil : mode
    }

    /// The modes to choose from: all three with a Pencil that reports its force, Apple Pencil alone or fingers too
    /// otherwise.
    var modes: [Mode] { hasPressure ? Mode.allCases : [.pencil, .finger] }

    /// The mode's name, as the toolbar's menu lists it.
    static func title(of mode: Mode) -> String {
        switch mode {
        case .pressure: "Pressure Sensitivity"
        case .pencil: "Pencil"
        case .finger: "Finger Touch"
        }
    }

    /// Who draws in `mode`, said so it holds on its own, without knowing what drew before: in the status line as it
    /// changes, and to VoiceOver on the toolbar's item. With a Pencil that reports its force, whether its pressure
    /// counts too.
    static func description(of mode: Mode, hasPressure: Bool) -> String {
        let pressure = hasPressure ? " · Every stroke at full pressure" : ""
        return switch mode {
        case .pressure: "Draw with Apple Pencil only · Its pressure sets the brush"
        case .pencil: "Draw with Apple Pencil only" + pressure
        case .finger: "Draw with fingers and Apple Pencil" + pressure
        }
    }

    /// The mode's symbol: a Pencil's stroke with its pressure, Apple Pencil alone, or a finger drawing too.
    static func symbol(of mode: Mode) -> String {
        switch mode {
        case .pressure: "pencil.and.scribble"
        case .pencil: "pencil"
        case .finger: "hand.tap"
        }
    }

    /// The toolbar item's color in `mode`, so the mode shows at a glance: purple for the pressure, blue for Apple Pencil
    /// alone, and none, the item's own, with fingers drawing too.
    static func tint(of mode: Mode) -> UIColor? {
        switch mode {
        case .pressure: .systemPurple
        case .pencil: .systemBlue
        case .finger: nil
        }
    }
}
