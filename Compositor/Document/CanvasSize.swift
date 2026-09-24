import Foundation
import CoreGraphics

nonisolated enum CanvasUnit: String, CaseIterable, Sendable {
    case pixels = "Pixels", percent = "Percent", inches = "Inches", centimeters = "Centimeters"
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
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
        let original = Double(widthAxis ? originalWidth : originalHeight)
        let pixels = (widthAxis ? width : height) - (relative ? original : 0)
        switch unit {
        case .pixels: return pixels
        case .percent: return pixels / original * 100
        case .inches: return pixels / resolution
        case .centimeters: return pixels / resolution * 2.54
        }
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
