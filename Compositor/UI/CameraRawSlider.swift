import AppKit
import SwiftUI

/// The colored tracks used by Camera Raw's color sliders. Plain sliders keep the system track.
enum CameraRawSliderTrack {
    case plain
    case temperature
    case tint
    case chroma
    /// Neighboring hues around a color-family center, in degrees.
    case hue(Double)
    /// Gray to that family's own color.
    case saturation(Double)
    /// Dark to light in that family's hue.
    case luminance(Double)
    /// One color to its opposite, as Color Balance's Cyan / Red.
    case opposing(NSColor, NSColor)
    /// The whole hue circle, with that hue in the middle.
    case spectrum(Double)

    /// Left-to-right track colors. Nil keeps the system track.
    var colors: [NSColor]? {
        switch self {
        case .plain:
            return nil
        case .temperature:
            return [NSColor(srgbRed: 0.22, green: 0.46, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.98, green: 0.82, blue: 0.18, alpha: 1)]
        case .tint:
            return [NSColor(srgbRed: 0.28, green: 0.70, blue: 0.34, alpha: 1),
                    NSColor(srgbRed: 0.70, green: 0.40, blue: 0.64, alpha: 1)]
        case .chroma:
            return [NSColor(srgbRed: 0.62, green: 0.62, blue: 0.64, alpha: 1),
                    NSColor(srgbRed: 0.86, green: 0.18, blue: 0.20, alpha: 1)]
        case .hue(let degrees):
            return [Self.color(degrees: degrees - 50, saturation: 0.85, brightness: 0.9),
                    Self.color(degrees: degrees + 50, saturation: 0.85, brightness: 0.9)]
        case .saturation(let degrees):
            return [NSColor(srgbRed: 0.55, green: 0.55, blue: 0.56, alpha: 1),
                    Self.color(degrees: degrees, saturation: 0.9, brightness: 0.9)]
        case .luminance(let degrees):
            return [Self.color(degrees: degrees, saturation: 0.55, brightness: 0.18),
                    Self.color(degrees: degrees, saturation: 0.35, brightness: 0.95)]
        case .opposing(let from, let to):
            return [from, to]
        case .spectrum(let degrees):
            return stride(from: -180.0, through: 180, by: 30).map { Self.color(degrees: degrees + $0, saturation: 0.85, brightness: 0.9) }
        }
    }

    private static func color(degrees: Double, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        var turns = degrees / 360
        turns -= floor(turns)
        return NSColor(hue: turns, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

/// Camera Raw slider. A double-click on the knob restores the default. A gradient track, when set, colors the whole
/// track, not only the side before the knob.
struct CameraRawSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var track: CameraRawSliderTrack
    var help: String
    var onChange: (Double) -> Void
    var onReset: () -> Void

    var body: some View {
        SliderTrackView(fraction: SliderGeometry.fraction(of: value, in: range),
                        colors: track.colors?.map { Color(nsColor: $0) },
                        onBegin: {},
                        onChange: { fraction in onChange(range.lowerBound + fraction * (range.upperBound - range.lowerBound)) },
                        onEnd: {},
                        onReset: onReset)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityValue(Text(String(format: "%.0f", value)))
            .accessibilityAdjustableAction { direction in
                let nudge = (range.upperBound - range.lowerBound) / 20
                switch direction {
                case .increment: onChange(min(range.upperBound, value + nudge))
                case .decrement: onChange(max(range.lowerBound, value - nudge))
                @unknown default: break
                }
            }
    }
}
