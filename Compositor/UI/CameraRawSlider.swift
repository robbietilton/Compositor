import AppKit
import SwiftUI

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
                        colors: track.colors?.map { Color(nsColor: $0.nsColor) },
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
