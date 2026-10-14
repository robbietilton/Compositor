import Foundation

/// The Image Size dialog's fields and the rules between them, apart from the views that show them: the new size in
/// pixels and the resolution, given in any of the canvas's units, with or without resampling.
nonisolated struct ImageSizeDraft {
    let originalWidth: Int
    let originalHeight: Int
    /// The new size in pixels.
    private(set) var width: Double
    private(set) var height: Double
    private(set) var resolution: Double
    /// The last usable resolution. Print sizes scale from it, so passing through a zero or negative entry
    /// doesn't lose them.
    private var lastResolution: Double
    var locked = true
    /// Without resampling only the print size and the resolution change; the pixels stay as they are.
    private(set) var resample = true
    var unit: CanvasUnit = .pixels
    var sampling: LayerSampling = .high

    init(width: Int, height: Int, resolution: Double) {
        originalWidth = width
        originalHeight = height
        self.width = Double(width)
        self.height = Double(height)
        self.resolution = resolution
        lastResolution = resolution
    }

    /// The units the size can be given in: without resampling, only print sizes.
    var units: [CanvasUnit] { CanvasUnit.allCases.filter { resample || ($0 != .pixels && $0 != .percent) } }

    var valid: Bool {
        width.isFinite && height.isFinite && resolution.isFinite && (1...9600).contains(resolution)
            && (1...DocumentLimits.maxSideExtent).contains(width.rounded()) && (1...DocumentLimits.maxSideExtent).contains(height.rounded())
            && (!resample || width.rounded() * height.rounded() <= DocumentLimits.maxSurfaceExtent)
    }

    /// What to resize to, once the fields add up.
    var options: ImageSizeOptions? {
        guard valid else { return nil }
        return ImageSizeOptions(width: Int(width.rounded()), height: Int(height.rounded()), resolution: resolution, sampling: sampling)
    }

    private var printUnit: Bool { unit == .inches || unit == .centimeters }

    /// The width or height in the unit chosen.
    func displayed(widthAxis: Bool) -> Double {
        displayed(widthAxis ? width : height, widthAxis: widthAxis)
    }

    private func displayed(_ pixels: Double, widthAxis: Bool) -> Double {
        switch unit {
        case .percent: return pixels / Double(widthAxis ? originalWidth : originalHeight) * 100
        case .inches: return pixels / resolution
        case .centimeters: return pixels / resolution * 2.54
        case .pixels: return pixels
        }
    }

    /// Sets the width or height in the unit chosen. Resampling, the pixels change, and with the ratio locked the other
    /// side's with them; otherwise the resolution does.
    mutating func set(_ value: Double, widthAxis: Bool) {
        guard value.isFinite, value > 0 else { return }
        if printUnit, !(resolution.isFinite && resolution > 0) { return }
        if !resample {
            setResolution((widthAxis ? width : height) / value * (unit == .centimeters ? 2.54 : 1))
            return
        }
        let pixels: Double
        switch unit {
        case .percent: pixels = value / 100 * Double(widthAxis ? originalWidth : originalHeight)
        case .inches: pixels = value * resolution
        case .centimeters: pixels = value / 2.54 * resolution
        case .pixels: pixels = value
        }
        if widthAxis {
            if locked { height = pixels * height / width }
            width = pixels
        } else {
            if locked { width = pixels * width / height }
            height = pixels
        }
    }

    /// Sets the resolution. Resampling a size given in print units keeps its print size, so its pixels scale with it.
    mutating func setResolution(_ value: Double) {
        resolution = value
        guard value.isFinite, value > 0 else { return }
        if resample, printUnit {
            width *= value / lastResolution
            height *= value / lastResolution
        }
        lastResolution = value
    }

    /// Turns resampling on or off. Off, the size goes back to the image's own pixels, the ratio locks, and the size is
    /// given in print units.
    mutating func setResample(_ enabled: Bool) {
        resample = enabled
        guard !enabled else { return }
        width = Double(originalWidth)
        height = Double(originalHeight)
        locked = true
        if !printUnit { unit = .inches }
    }

    /// Whether the width and height can be scrubbed: print units need a resolution to count in.
    var canScrubDimensions: Bool { !printUnit || (resolution.isFinite && resolution > 0) }

    /// How far scrubbing the width or height can take it, in the unit chosen.
    func scrubRange(widthAxis: Bool) -> ClosedRange<Double> {
        guard canScrubDimensions else { return 0...0 }
        let pixels = widthAxis ? width : height
        let other = widthAxis ? height : width
        if !resample {
            let multiplier = unit == .centimeters ? 2.54 : 1.0
            return pixels * multiplier / 9600...pixels * multiplier
        }
        let minimum = locked ? max(1, pixels / other) : 1.0
        let dimensionLimit = locked ? min(30_000, 30_000 * pixels / other) : 30_000.0
        let areaLimit = locked ? sqrt(100_000_000 * pixels / other) : 100_000_000 / other
        let maximum = max(minimum, min(dimensionLimit, areaLimit))
        return displayed(minimum, widthAxis: widthAxis)...displayed(maximum, widthAxis: widthAxis)
    }

    /// How much a point of scrubbing changes the width or height, in the unit chosen.
    func scrubSensitivity(widthAxis: Bool) -> Double {
        guard canScrubDimensions else { return 0 }
        if !resample { return unit == .centimeters ? 0.0254 : 0.01 }
        switch unit {
        case .percent: return 100 / Double(widthAxis ? originalWidth : originalHeight)
        case .inches: return 1 / resolution
        case .centimeters: return 2.54 / resolution
        case .pixels: return 1
        }
    }
}
