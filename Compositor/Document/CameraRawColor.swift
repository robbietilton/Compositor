import AppKit

nonisolated enum CameraRawCurvePage: String, CaseIterable, Sendable { case parametric = "Parametric", point = "Point" 
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}
nonisolated enum CameraRawPointChannel: String, CaseIterable, Sendable { case rgb = "RGB", red = "Red", green = "Green", blue = "Blue" 
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}
nonisolated enum CameraRawMixerPage: String, CaseIterable, Sendable { case hsl = "HSL", color = "Color", point = "Point Color" 
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}
nonisolated enum CameraRawMixerTab: String, CaseIterable, Sendable { case hue = "Hue", saturation = "Saturation", luminance = "Luminance" 
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}
nonisolated enum CameraRawGradePage: String, CaseIterable, Sendable {
    case threeWay = "Three-Way", shadows = "Shadows", midtones = "Midtones", highlights = "Highlights", global = "Global"

    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
}

struct CameraRawDrag {
    var startY: CGFloat
    var settings: CameraRawSettings
    var tone: Double
    var hue: Double
}

/// Parametric regions and point curves. Amounts are −100…100. Curve points use 0…1 on both axes.
nonisolated struct CameraRawCurveSettings: Equatable, Sendable {
    var shadows: Double = 0
    var darks: Double = 0
    var lights: Double = 0
    var highlights: Double = 0
    /// Dividers, 0…100, kept in order. They set where each parametric slider hands off to the next.
    var shadowSplit: Double = 25
    var darkSplit: Double = 50
    var lightSplit: Double = 75
    var rgb = Self.linear
    var red = Self.linear
    var green = Self.linear
    var blue = Self.linear
    /// How much the composite curve also changes saturation. 0 keeps it to brightness.
    var refineSaturation: Double = 0

    static let linear = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    static let mediumContrast = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.18), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1)]
    static let strongContrast = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.10), CurvePoint(x: 0.75, y: 0.90), CurvePoint(x: 1, y: 1)]

    var adjusts: Bool {
        shadows != 0 || darks != 0 || lights != 0 || highlights != 0 || refineSaturation != 0
            || !Self.isLinear(rgb) || !Self.isLinear(red) || !Self.isLinear(green) || !Self.isLinear(blue)
    }

    static func isLinear(_ points: [CurvePoint]) -> Bool {
        points.count == 2 && points[0].x == 0 && points[0].y == 0 && points[1].x == 1 && points[1].y == 1
    }

    /// Lifts or lowers the region a tone belongs to. Dividers are fractions of the tonal range.
    func parametric(_ tone: Double) -> Double {
        let shadow = shadowSplit / 100, dark = darkSplit / 100, light = lightSplit / 100
        let (amount, lo, hi): (Double, Double, Double)
        if tone < shadow { (amount, lo, hi) = (shadows, 0, shadow) }
        else if tone < dark { (amount, lo, hi) = (darks, shadow, dark) }
        else if tone < light { (amount, lo, hi) = (lights, dark, light) }
        else { (amount, lo, hi) = (highlights, light, 1) }
        let span = max(0.02, hi - lo)
        let weight = 1 - abs(tone - (lo + hi) / 2) / (span / 2)
        return min(1, max(0, tone + (amount / 100) * max(0, weight) * 0.22))
    }

    func lumaTable() -> [Float] { (0...255).map { Float(point(parametric(Double($0) / 255), rgb)) } }
    func channelTable(_ points: [CurvePoint]) -> [Float] { (0...255).map { Float(point(Double($0) / 255, points)) } }

    func nudged(_ channel: CameraRawPointChannel, near tone: Double, by delta: Double) -> Self {
        var result = self
        var points: [CurvePoint]
        switch channel {
        case .rgb: points = rgb
        case .red: points = red
        case .green: points = green
        case .blue: points = blue
        }
        guard let index = points.indices.min(by: { abs(points[$0].x - tone) < abs(points[$1].x - tone) }) else { return self }
        if index == 0 || index == points.count - 1 { points[index].y = min(1, max(0, points[index].y + delta)) }
        else {
            points[index].y = min(1, max(0, points[index].y + delta))
        }
        switch channel {
        case .rgb: result.rgb = points
        case .red: result.red = points
        case .green: result.green = points
        case .blue: result.blue = points
        }
        return result
    }

    /// The region name a tone belongs to, for the targeted adjustment tool.
    func region(for tone: Double) -> WritableKeyPath<Self, Double> {
        if tone < shadowSplit / 100 { return \.shadows }
        if tone < darkSplit / 100 { return \.darks }
        if tone < lightSplit / 100 { return \.lights }
        return \.highlights
    }

    var normalized: Self {
        var result = self
        result.shadows = ImageAdjustmentPixels.clamp(shadows, -100...100, 0)
        result.darks = ImageAdjustmentPixels.clamp(darks, -100...100, 0)
        result.lights = ImageAdjustmentPixels.clamp(lights, -100...100, 0)
        result.highlights = ImageAdjustmentPixels.clamp(highlights, -100...100, 0)
        result.refineSaturation = ImageAdjustmentPixels.clamp(refineSaturation, -100...100, 0)
        result.shadowSplit = ImageAdjustmentPixels.clamp(shadowSplit, 5...90, 25)
        result.darkSplit = ImageAdjustmentPixels.clamp(darkSplit, result.shadowSplit + 2...95, 50)
        result.lightSplit = ImageAdjustmentPixels.clamp(lightSplit, result.darkSplit + 2...98, 75)
        result.rgb = Self.repair(rgb)
        result.red = Self.repair(red)
        result.green = Self.repair(green)
        result.blue = Self.repair(blue)
        return result
    }

    private func point(_ x: Double, _ points: [CurvePoint]) -> Double {
        var curve = CurvesSettings()
        curve.channels[0] = points.map { CurvePoint(x: $0.x * 255, y: $0.y * 255) }
        guard curve.channels[0].count >= 2 else { return x }
        return curve.value(x * 255, channel: 0) / 255
    }

    private static func repair(_ points: [CurvePoint]) -> [CurvePoint] {
        var sorted = points.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.x < $1.x }
        if sorted.count < 2 { return linear }
        sorted[0] = CurvePoint(x: 0, y: min(1, max(0, sorted[0].y)))
        sorted[sorted.count - 1] = CurvePoint(x: 1, y: min(1, max(0, sorted[sorted.count - 1].y)))
        var kept: [CurvePoint] = [sorted[0]]
        for point in sorted.dropFirst().dropLast() {
            let x = min(0.99, max(0.01, point.x))
            guard x > kept[kept.count - 1].x + 0.01 else { continue }
            kept.append(CurvePoint(x: x, y: min(1, max(0, point.y))))
        }
        kept.append(sorted[sorted.count - 1])
        return kept
    }
}

/// Eight color families, each with hue, saturation, and luminance shifts of −100…100.
nonisolated struct CameraRawMixerSettings: Equatable, Sendable {
    static let names = ["Reds", "Oranges", "Yellows", "Greens", "Aquas", "Blues", "Purples", "Magentas"]
    static let centers = [0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0]
    var hue = Array(repeating: 0.0, count: 8)
    var saturation = Array(repeating: 0.0, count: 8)
    var luminance = Array(repeating: 0.0, count: 8)
    var points: [CameraRawPointColor] = []

    var adjusts: Bool {
        hue.contains { $0 != 0 } || saturation.contains { $0 != 0 } || luminance.contains { $0 != 0 }
            || points.contains { $0.hueShift != 0 || $0.saturationShift != 0 || $0.luminanceShift != 0 }
    }

    /// How much each family shares a hue, in degrees. Neighbors overlap.
    static func weights(forHue degrees: Double) -> [Double] {
        centers.map { center in
            var distance = abs(degrees - center)
            if distance > 180 { distance = 360 - distance }
            return max(0, 1 - distance / 40)
        }
    }

    var mixerFloats: [Float] {
        (hue + saturation + luminance).map { Float($0 / 100) }
    }

    var pointFloats: [Float] {
        points.flatMap { point in
            [point.hue / 360, point.saturation, point.luminance,
             point.hueShift / 100, point.saturationShift / 100, point.luminanceShift / 100,
             point.hueRange / 360, point.saturationRange, point.luminanceRange].map { Float($0) }
        }
    }

    var normalized: Self {
        var result = self
        result.hue = hue.map { ImageAdjustmentPixels.clamp($0, -100...100, 0) }
        result.saturation = saturation.map { ImageAdjustmentPixels.clamp($0, -100...100, 0) }
        result.luminance = luminance.map { ImageAdjustmentPixels.clamp($0, -100...100, 0) }
        result.points = Array(points.prefix(8)).map(\.normalized)
        return result
    }
}

/// One picked color and how far its adjustment reaches.
nonisolated struct CameraRawPointColor: Equatable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var hueShift: Double = 0
    var saturationShift: Double = 0
    var luminanceShift: Double = 0
    var hueRange: Double = 30
    var saturationRange: Double = 0.4
    var luminanceRange: Double = 0.4
    var visualize = false

    var normalized: Self {
        var result = self
        result.hue = ImageAdjustmentPixels.clamp(hue, 0...360, 0)
        result.saturation = ImageAdjustmentPixels.clamp(saturation, 0...1, 0)
        result.luminance = ImageAdjustmentPixels.clamp(luminance, 0...1, 0)
        result.hueShift = ImageAdjustmentPixels.clamp(hueShift, -100...100, 0)
        result.saturationShift = ImageAdjustmentPixels.clamp(saturationShift, -100...100, 0)
        result.luminanceShift = ImageAdjustmentPixels.clamp(luminanceShift, -100...100, 0)
        result.hueRange = ImageAdjustmentPixels.clamp(hueRange, 5...180, 30)
        result.saturationRange = ImageAdjustmentPixels.clamp(saturationRange, 0.05...1, 0.4)
        result.luminanceRange = ImageAdjustmentPixels.clamp(luminanceRange, 0.05...1, 0.4)
        return result
    }
}

/// Four color wheels plus how the three tonal wheels overlap and which end they favor.
nonisolated struct CameraRawGradingSettings: Equatable, Sendable {
    var shadows = CameraRawGradeWheel()
    var midtones = CameraRawGradeWheel()
    var highlights = CameraRawGradeWheel()
    var global = CameraRawGradeWheel()
    /// 0…100. Higher values let the three tonal wheels overlap more.
    var blending: Double = 50
    /// −100…100. Negative favors shadows, positive favors highlights.
    var balance: Double = 0

    var wheels: [CameraRawGradeWheel] { [shadows, midtones, highlights, global] }
    var adjusts: Bool { wheels.contains { $0.saturation != 0 || $0.luminance != 0 } }

    var gradeFloats: [Float] {
        wheels.flatMap { [Float($0.hue / 360), Float($0.saturation / 100), Float($0.luminance / 100)] }
    }

    var normalized: Self {
        var result = self
        result.shadows = shadows.normalized
        result.midtones = midtones.normalized
        result.highlights = highlights.normalized
        result.global = global.normalized
        result.blending = ImageAdjustmentPixels.clamp(blending, 0...100, 50)
        result.balance = ImageAdjustmentPixels.clamp(balance, -100...100, 0)
        return result
    }
}

nonisolated struct CameraRawGradeWheel: Equatable, Sendable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var normalized: Self {
        Self(hue: ImageAdjustmentPixels.clamp(hue, 0...360, 0),
             saturation: ImageAdjustmentPixels.clamp(saturation, 0...100, 0),
             luminance: ImageAdjustmentPixels.clamp(luminance, -100...100, 0))
    }
}

extension CameraRawSettings {
    /// Runs Curve, then Color Mixer, then Color Grading. `visualize` dims pixels outside that point color.
    func applyCurveColor(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, visualize: Int) {
        let curve = curve.normalized
        let mixer = mixer.normalized
        let grading = grading.normalized
        let luma = curve.lumaTable()
        let red = curve.channelTable(curve.red)
        let green = curve.channelTable(curve.green)
        let blue = curve.channelTable(curve.blue)
        let mixerFloats = mixer.mixerFloats
        let pointFloats = mixer.pointFloats
        let grade = grading.gradeFloats
        luma.withUnsafeBufferPointer { lumaP in
            red.withUnsafeBufferPointer { redP in
                green.withUnsafeBufferPointer { greenP in
                    blue.withUnsafeBufferPointer { blueP in
                        mixerFloats.withUnsafeBufferPointer { mixerP in
                            pointFloats.withUnsafeBufferPointer { pointP in
                                grade.withUnsafeBufferPointer { gradeP in
                                    adjust_camera_raw_curve_color(pixels, width, height, stride,
                                                                  lumaP.baseAddress, redP.baseAddress, greenP.baseAddress, blueP.baseAddress,
                                                                  curve.refineSaturation / 100, mixerP.baseAddress,
                                                                  Int32(mixer.points.count), pointP.baseAddress,
                                                                  gradeP.baseAddress, grading.blending / 100, grading.balance / 100, Int32(visualize))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
