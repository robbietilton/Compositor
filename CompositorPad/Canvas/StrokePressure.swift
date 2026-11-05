import CoreGraphics
import Observation

/// The pressure the brush paints at under the stroke going on, for the Brush bar's Size and Opacity to show live: what
/// the editor keeps for the stroke, which it doesn't publish, handed on by the canvas once a frame, as it draws it. A
/// Pencil's 240 samples a second would otherwise update the bar four times a frame.
@MainActor @Observable final class StrokePressure {
    /// The pressure, 0–1, while a stroke is down. Set to what it already is, it changes nothing, so what follows it isn't
    /// updated for it.
    var value: CGFloat?
}
