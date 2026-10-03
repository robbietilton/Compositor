import AppKit
import SwiftUI

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
        slider.toolTip = help
        slider.onReset = context.coordinator.reset
        slider.onTrackClick = context.coordinator.onChange
        (slider.cell as? GradientSliderCell)?.gradientColors = track.colors?.map(\.nsColor)
        slider.setAccessibilityLabel(help)
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
        slider.toolTip = help
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        if !slider.isTrackingValue { slider.doubleValue = value }
        if track.colors != nil, !(slider.cell is GradientSliderCell) {
            let value = slider.doubleValue
            slider.cell = GradientSliderCell()
            slider.doubleValue = value
        }
        if let cell = slider.cell as? GradientSliderCell {
            cell.gradientColors = track.colors?.map(\.nsColor)
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
