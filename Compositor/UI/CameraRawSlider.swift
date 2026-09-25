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
        }
    }

    private static func color(degrees: Double, saturation: CGFloat, brightness: CGFloat) -> NSColor {
        var turns = degrees / 360
        turns -= floor(turns)
        return NSColor(hue: turns, saturation: saturation, brightness: brightness, alpha: 1)
    }
}

/// Camera Raw slider. A double-click on the knob restores the default. A gradient track, when set,
/// replaces the system bar so the whole track shows the color, not only the side before the knob.
struct CameraRawSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var track: CameraRawSliderTrack
    var help: String
    var onChange: (Double) -> Void
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onReset: onReset)
    }

    func makeNSView(context: Context) -> CameraRawSliderView {
        let slider = CameraRawSliderView()
        if track.colors != nil { slider.cell = GradientSliderCell() }
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.toolTip = localized(help)
        slider.onReset = context.coordinator.reset
        slider.onTrackClick = context.coordinator.onChange
        (slider.cell as? GradientSliderCell)?.gradientColors = track.colors
        slider.setAccessibilityLabel(localized(help))
        return slider
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CameraRawSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: 22)
    }

    func updateNSView(_ slider: CameraRawSliderView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onReset = onReset
        slider.onReset = context.coordinator.reset
        slider.onTrackClick = context.coordinator.onChange
        slider.toolTip = localized(help)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if !slider.isTrackingValue { slider.doubleValue = value }
        if track.colors != nil, !(slider.cell is GradientSliderCell) {
            let value = slider.doubleValue
            slider.cell = GradientSliderCell()
            slider.doubleValue = value
        }
        if let cell = slider.cell as? GradientSliderCell {
            cell.gradientColors = track.colors
            slider.needsDisplay = true
        }
    }

    final class Coordinator: NSObject {
        var onChange: (Double) -> Void
        var onReset: () -> Void
        init(onChange: @escaping (Double) -> Void, onReset: @escaping () -> Void) {
            self.onChange = onChange
            self.onReset = onReset
        }
        func reset() { onReset() }
        @objc func changed(_ sender: NSSlider) { onChange(sender.doubleValue) }
    }
}

final class CameraRawSliderView: NSSlider {
    var onReset: (() -> Void)?
    var onTrackClick: ((Double) -> Void)?
    /// True while a press is being tracked, so a binding update does not fight the drag.
    private(set) var isTrackingValue = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, isOnKnob(point) {
            onReset?()
            return
        }
        // A synthetic click with the button already up must not enter tracking: that loop waits for a mouse-up that never arrives.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        isTrackingValue = true
        if !isOnKnob(point) {
            animateTrackClick(to: value(at: point))
            return
        }
        super.mouseDown(with: event)
        isTrackingValue = false
    }

    /// SwiftUI's sliders glide their knob from its current position when the track is clicked.
    /// NSSlider's cell-level tracking is globally adjusted elsewhere in the app, so reproduce that
    /// visual behavior here while publishing the destination value only once.
    private func animateTrackClick(to target: Double) {
        onTrackClick?(target)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().doubleValue = target
        } completionHandler: { [weak self] in
            self?.isTrackingValue = false
        }
    }

    func value(at point: NSPoint) -> Double {
        guard let cell = cell as? NSSliderCell else { return doubleValue }
        let knob = cell.knobRect(flipped: isFlipped)
        let track = cell.trackRect.isEmpty ? bounds : cell.trackRect
        let travel = track.width - knob.width
        guard travel > 0 else { return doubleValue }
        var fraction = min(1, max(0, (point.x - track.minX - knob.width / 2) / travel))
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        return minValue + Double(fraction) * (maxValue - minValue)
    }

    /// The drawn knob, or the cell's knob rectangle when the slider has not built a knob view yet.
    func isOnKnob(_ point: NSPoint) -> Bool {
        if let knob = knobView {
            return knob.frame.insetBy(dx: -2, dy: -2).contains(point)
        }
        guard let cell = cell as? NSSliderCell else { return false }
        return cell.knobRect(flipped: isFlipped).insetBy(dx: -2, dy: -2).contains(point)
    }

    private var knobView: NSView? {
        func find(_ view: NSView) -> NSView? {
            for child in view.subviews {
                if child.frame.width < 60, child.frame.width > 4 { return child }
                if let found = find(child) { return found }
            }
            return nil
        }
        return find(self)
    }
}

final class GradientSliderCell: NSSliderCell {
    var gradientColors: [NSColor]?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let gradientColors, gradientColors.count >= 2, let gradient = NSGradient(colors: gradientColors) else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }
        let height: CGFloat = 4
        let bar = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        gradient.draw(in: NSBezierPath(roundedRect: bar, xRadius: height / 2, yRadius: height / 2), angle: 0)
    }
}
