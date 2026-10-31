import Foundation
import Observation

/// Who draws on the canvas: fingers, until Apple Pencil turns up, and then Apple Pencil alone, with fingers moving the
/// canvas, or fingers too, as the toolbar's switch says. iPadOS doesn't tell an app whether a Pencil is paired or
/// connected, only what it does: one turns up when it touches the canvas, hovers over it, or is tapped or squeezed, and
/// each launch starts without one.
@MainActor @Observable final class DrawingInput {
    static let shared = DrawingInput(defaults: .standard)

    /// Whether Apple Pencil has turned up since launch.
    private(set) var hasPencil = false
    /// Once it has, whether only Apple Pencil draws, fingers moving the canvas. Kept across launches.
    var pencilOnly: Bool {
        didSet { defaults.set(pencilOnly, forKey: Self.pencilOnlyKey) }
    }
    /// Whether a finger draws.
    var fingerPaints: Bool { !hasPencil || !pencilOnly }

    @ObservationIgnored private let defaults: UserDefaults
    private static let pencilOnlyKey = "pencilOnly"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pencilOnly = defaults.object(forKey: Self.pencilOnlyKey) as? Bool ?? true
    }

    /// Who draws, said so it holds on its own, without knowing what drew before: on the toolbar's switch, and in the
    /// status line as the switch flips.
    static func description(pencilOnly: Bool) -> String {
        pencilOnly ? "Draw with Apple Pencil only" : "Draw with fingers and Apple Pencil"
    }

    /// The switch's symbol: Apple Pencil drawing alone, or a finger drawing too.
    static func symbol(pencilOnly: Bool) -> String { pencilOnly ? "applepencil.and.scribble" : "hand.tap" }

    /// Apple Pencil touching, hovering, or tapped or squeezed. True the first time since launch, when it takes drawing
    /// from fingers.
    @discardableResult func pencilTurnedUp() -> Bool {
        guard !hasPencil else { return false }
        hasPencil = true
        return pencilOnly
    }
}
