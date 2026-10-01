import Foundation
import CoreGraphics

nonisolated enum CanvasUnit: String, CaseIterable, Sendable {
    case pixels = "Pixels", percent = "Percent", inches = "Inches", centimeters = "Centimeters"
}

nonisolated struct CanvasSizeDraft {
    let originalWidth: Int
    let originalHeight: Int
    let resolution: Double
    var width: Double
    var height: Double
    var relative = false
    var locked = false
    var unit: CanvasUnit = .pixels

    init(width: Int, height: Int, resolution: Double) {
        originalWidth = width
        originalHeight = height
        self.width = Double(width)
        self.height = Double(height)
        self.resolution = resolution
    }

    var valid: Bool {
        width.isFinite && height.isFinite && (1...DocumentLimits.maxSideExtent).contains(width.rounded())
            && (1...DocumentLimits.maxSideExtent).contains(height.rounded())
    }

    func displayed(widthAxis: Bool) -> Double {
        displayed(widthAxis ? width : height, widthAxis: widthAxis)
    }

    /// `pixels` along an axis in the unit chosen, less the current size when relative.
    private func displayed(_ pixels: Double, widthAxis: Bool) -> Double {
        let original = Double(widthAxis ? originalWidth : originalHeight)
        let difference = pixels - (relative ? original : 0)
        switch unit {
        case .pixels: return difference
        case .percent: return difference / original * 100
        case .inches: return difference / resolution
        case .centimeters: return difference / resolution * 2.54
        }
    }

    /// How far scrubbing the width or height can take it, in the unit chosen.
    func scrubRange(widthAxis: Bool) -> ClosedRange<Double> {
        let original = Double(widthAxis ? originalWidth : originalHeight)
        let other = Double(widthAxis ? originalHeight : originalWidth)
        let lower = locked ? max(1, original / other) : 1.0
        let upper = locked ? min(30_000, 30_000 * original / other) : 30_000.0
        return displayed(lower, widthAxis: widthAxis)...displayed(upper, widthAxis: widthAxis)
    }

    /// How much a point of scrubbing changes the width or height, in the unit chosen.
    func scrubSensitivity(widthAxis: Bool) -> Double {
        switch unit {
        case .pixels: return 1
        case .percent: return 100 / Double(widthAxis ? originalWidth : originalHeight)
        case .inches: return 1 / resolution
        case .centimeters: return 2.54 / resolution
        }
    }

    /// What an uncompressed RGBA canvas of `width` × `height` takes in memory, as the dialog shows it.
    static func memory(width: Int, height: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(width) * Int64(height) * 4, countStyle: .memory)
    }

    mutating func set(_ value: Double, widthAxis: Bool) {
        let original = Double(widthAxis ? originalWidth : originalHeight)
        let pixels: Double
        switch unit {
        case .pixels: pixels = value
        case .percent: pixels = value / 100 * original
        case .inches: pixels = value * resolution
        case .centimeters: pixels = value / 2.54 * resolution
        }
        let final = pixels + (relative ? original : 0)
        if widthAxis {
            width = final
            if locked { height = final * Double(originalHeight) / Double(originalWidth) }
        } else {
            height = final
            if locked { width = final * Double(originalWidth) / Double(originalHeight) }
        }
    }
}

nonisolated struct CanvasSizeOptions: Sendable {
    let width: Int
    let height: Int
    var anchor = 4 // Row-major, top-left through bottom-right.
    var fill: CanvasExtensionColor? = nil
    var contentOffset: CGPoint? = nil // Crop supplies an explicit document-space translation.

    func offset(fromWidth: Int, height oldHeight: Int) -> CGPoint {
        if let contentOffset { return contentOffset }
        // Floor puts the extra pixel on the right/bottom when expanding,
        // and removes it from the left/top when shrinking around the center.
        return CGPoint(x: floor(Double(width - fromWidth) * Double(anchor % 3) / 2),
                y: floor(Double(height - oldHeight) * Double(anchor / 3) / 2))
    }
}

nonisolated struct CanvasExtensionColor: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}
