import Foundation

/// The brush tips, the Brush's mode and the two colors belong to the person too (`ToolDefaults`): a new document
/// starts with them as they were last left, in any document, as Photoshop's do.
nonisolated struct BrushDefaults: Equatable, Sendable {
    struct Tip: Equatable, Sendable {
        var diameter: CGFloat
        var hardness: CGFloat
        var opacity: CGFloat
    }
    /// One tip per family: Brush and Spot Healing, Clone Stamp, then Smear. The last two start soft.
    var tips = [Tip(diameter: 40, hardness: 1, opacity: 1), Tip(diameter: 40, hardness: 0, opacity: 1), Tip(diameter: 40, hardness: 0, opacity: 1)]
    var smoothing: CGFloat = 0
    var mode = BrushToolMode.paint
    var foreground = PaletteColor.black
    var background = PaletteColor.white

    private static let families = ["brush", "clone", "smear"]

    static func load() -> BrushDefaults {
        var result = BrushDefaults()
        for (family, name) in families.enumerated() {
            let fallback = result.tips[family]
            result.tips[family] = Tip(diameter: number(name + "Size", fallback.diameter, in: 1...2000),
                                      hardness: number(name + "Hardness", fallback.hardness, in: 0...1),
                                      opacity: number(name + "Opacity", fallback.opacity, in: 0.01...1))
        }
        result.smoothing = number("brushSmoothing", result.smoothing, in: 0...100)
        result.mode = BrushToolMode(rawValue: ToolDefaults.string("brushMode", "")) ?? result.mode
        result.foreground = PaletteColor(hex: ToolDefaults.string("foregroundColor", "")) ?? result.foreground
        result.background = PaletteColor(hex: ToolDefaults.string("backgroundColor", "")) ?? result.background
        return result
    }

    /// Writes only what differs from `old`, so documents open side by side don't write back each other's settings.
    func save(since old: BrushDefaults) {
        for (family, name) in Self.families.enumerated() where tips[family] != old.tips[family] {
            ToolDefaults.set(Double(tips[family].diameter), name + "Size")
            ToolDefaults.set(Double(tips[family].hardness), name + "Hardness")
            ToolDefaults.set(Double(tips[family].opacity), name + "Opacity")
        }
        if smoothing != old.smoothing { ToolDefaults.set(Double(smoothing), "brushSmoothing") }
        if mode != old.mode { ToolDefaults.set(mode.rawValue, "brushMode") }
        if foreground != old.foreground { ToolDefaults.set(foreground.hex, "foregroundColor") }
        if background != old.background { ToolDefaults.set(background.hex, "backgroundColor") }
    }

    private static func number(_ key: String, _ fallback: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let saved = CGFloat(ToolDefaults.double(key, Double(fallback)))
        return saved.isFinite ? min(range.upperBound, max(range.lowerBound, saved)) : fallback
    }
}
