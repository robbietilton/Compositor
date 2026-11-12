import Foundation

nonisolated struct BrushProperties: Codable, Equatable, Hashable, Sendable {
    var minimumSize: CGFloat = 1
    var maximumSize: CGFloat = 2000
    var minimumOpacity: CGFloat = 0
    var maximumOpacity: CGFloat = 1
    var smudgePull: CGFloat = 1
    var orientToScreen = true
    var isValid: Bool {
        [minimumSize, maximumSize, minimumOpacity, maximumOpacity, smudgePull].allSatisfy(\.isFinite)
            && 1 <= minimumSize && minimumSize <= maximumSize && maximumSize <= 2000
            && 0 <= minimumOpacity && minimumOpacity <= maximumOpacity && (0.01...1).contains(maximumOpacity)
            && (0...1).contains(smudgePull)
    }
}

nonisolated struct BrushTaper: Codable, Equatable, Hashable, Sendable {
    var start: CGFloat = 0
    var end: CGFloat = 0
    var linked = false
    var size: CGFloat = 1
    var opacity: CGFloat = 0
    var pressure: CGFloat = 0
    var tip: CGFloat = 0.5
    var isActive: Bool { start > 0 || end > 0 }
    var isValid: Bool { [start, end, size, opacity, pressure, tip].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    func response(distance: CGFloat, total: CGFloat, input: CGFloat?, classic: Bool = false) -> (size: CGFloat, opacity: CGFloat) {
        guard total > 0 else { return (1, 1) }
        let ramp = max(0, min(1, min(start > 0 ? distance / (total * start) : 1,
                                     end > 0 ? (total - distance) / (total * end) : 1)))
        let eased = classic ? ramp : pow(ramp, 0.25 + 3.75 * tip)
        let response = eased * (1 - pressure) + eased * (input ?? 1) * pressure
        return (1 - size * (1 - response), 1 - opacity * (1 - response))
    }
}

nonisolated struct BrushStabilization: Codable, Equatable, Hashable, Sendable {
    var streamline: CGFloat = 0
    var pressure: CGFloat = 0
    var stabilization: CGFloat = 0
    var motion: CGFloat = 0
    var expression: CGFloat = 0
    var isActive: Bool { streamline > 0 || pressure > 0 || stabilization > 0 || motion > 0 }
    var isValid: Bool { [streamline, pressure, stabilization, motion, expression].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    /// Native cascade: direction smoothing, low-pass stabilization, then a screen-space deadband.
    func point(_ point: CGPoint, previous: CGPoint, rawPrevious: CGPoint, zoom: CGFloat) -> CGPoint {
        guard isActive else { return point }
        let delta = hypot(point.x - rawPrevious.x, point.y - rawPrevious.y) * max(0.01, zoom)
        let expressive = min(1, delta / 40) * expression
        let tracked = Self.follow(point, from: previous, radius: 40 * streamline / max(0.01, zoom)) ?? previous
        let gain = 1 - 0.95 * stabilization * (1 - expressive)
        let filtered = CGPoint(x: previous.x + (tracked.x - previous.x) * gain, y: previous.y + (tracked.y - previous.y) * gain)
        let dx = filtered.x - previous.x, dy = filtered.y - previous.y, distance = hypot(dx, dy)
        let deadband = 20 * motion * (1 - expressive) / max(0.01, zoom)
        guard distance > deadband else { return previous }
        return CGPoint(x: previous.x + dx * (distance - deadband) / distance, y: previous.y + dy * (distance - deadband) / distance)
    }
    static func follow(_ point: CGPoint, from anchor: CGPoint, radius: CGFloat) -> CGPoint? {
        let dx = point.x - anchor.x, dy = point.y - anchor.y, distance = hypot(dx, dy)
        guard distance > radius else { return radius == 0 ? point : nil }
        let step = (distance - radius) / distance
        return CGPoint(x: anchor.x + dx * step, y: anchor.y + dy * step)
    }

}

nonisolated struct BrushGrain: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case moving = "Moving", texturized = "Texturized" }
    enum Source: String, Codable, CaseIterable, Sendable { case generated = "Native Texture", custom = "Custom Image", original = "Original Embedded Image" }
    enum Blend: String, Codable, CaseIterable, Sendable { case multiply = "Multiply", screen = "Screen", overlay = "Overlay", subtract = "Subtract" }
    var source: Source = .generated
    var custom: BrushShapeTip? = nil
    var mode: Mode = .texturized
    var scale: CGFloat = 64
    var depth: CGFloat = 1
    var brightness: CGFloat = 0
    var contrast: CGFloat = 0
    var movement: CGFloat = 1
    var zoom: CGFloat = 0
    var depthJitter: CGFloat = 0
    var offsetJitter: CGFloat = 0
    var rotation: CGFloat = 0
    var blend: Blend = .multiply
    var filtering: ShapeBrushSettings.Filtering = .classic
    var isValid: Bool {
        [scale, depth, brightness, contrast, movement, rotation, zoom, depthJitter, offsetJitter].allSatisfy(\.isFinite)
            && (1...2000).contains(scale) && (0...1).contains(depth) && (-1...1).contains(brightness)
            && (-1...1).contains(contrast) && [zoom, depthJitter, offsetJitter].allSatisfy { (0...1).contains($0) } && (0...1).contains(movement) && (-CGFloat.pi...CGFloat.pi).contains(rotation)
            && (source != .custom || custom?.isValid == true)
    }
    static func texture() -> BrushShapeTip { nativeTexture }
    private static let nativeTexture: BrushShapeTip = {
        let side = 128
        let pixels = Data((0..<(side * side)).map { i in
            let x = Double(i % side), y = Double(i / side)
            return UInt8(max(0, min(255, 128 + 65 * sin(x * 2 * .pi / 16) * cos(y * 2 * .pi / 32) + 40 * sin((x + y) * 2 * .pi / 8))))
        })
        return BrushShapeTip(side: side, luminance: pixels, alpha: Data(repeating: 255, count: side * side), name: "Native Woven Texture")
    }()
}

/// Native normalized wet controls; absent or default settings preserve dry Rendering.
nonisolated struct BrushWetMix: Codable, Equatable, Hashable, Sendable {
    var dilution: CGFloat = 0
    var charge: CGFloat = 1
    var attack: CGFloat = 1
    var pull: CGFloat = 0
    var grade: CGFloat = 0
    var blur: CGFloat = 0
    var blurJitter: CGFloat = 0
    var wetnessJitter: CGFloat = 0
    var isActive: Bool { self != Self() }
    var isValid: Bool {
        [dilution, charge, attack, pull, grade, blur, blurJitter, wetnessJitter]
            .allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// Normalized native color responses; zero is an exact identity.
nonisolated struct BrushColorResponse: Codable, Equatable, Hashable, Sendable {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var lightness: CGFloat = 0
    var darkness: CGFloat = 0
    var secondary: CGFloat = 0
    var isActive: Bool { self != Self() }
    var isValid: Bool {
        [hue, saturation].allSatisfy { $0.isFinite && (-1...1).contains($0) }
            && [lightness, darkness, secondary].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    func randomized(seed: UInt64, index: Int, channel: Int) -> Self {
        guard isActive else { return self }
        return Self(hue: hue * (2 * brushRandomUnit(seed: seed, index: index, channel: channel) - 1),
            saturation: saturation * (2 * brushRandomUnit(seed: seed, index: index, channel: channel + 1) - 1),
            lightness: lightness * brushRandomUnit(seed: seed, index: index, channel: channel + 2),
            darkness: darkness * brushRandomUnit(seed: seed, index: index, channel: channel + 3),
            secondary: secondary * brushRandomUnit(seed: seed, index: index, channel: channel + 4))
    }
    func applying(to color: PaletteColor, secondaryColor: PaletteColor, factor: CGFloat = 1) -> PaletteColor {
        guard isActive, factor > 0 else { return color }
        let mix = secondary * factor
        let mixed = PaletteColor(red: color.red + (secondaryColor.red - color.red) * mix,
            green: color.green + (secondaryColor.green - color.green) * mix,
            blue: color.blue + (secondaryColor.blue - color.blue) * mix)
        guard hue != 0 || saturation != 0 || lightness != 0 || darkness != 0 else { return mixed }
        var (h, s, l) = HueSaturationFilter.toHSL(red: Double(mixed.red), green: Double(mixed.green), blue: Double(mixed.blue))
        h = (h + Double(hue * factor) * 180).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = min(1, max(0, s + Double(saturation * factor)))
        l += (1 - l) * Double(lightness * factor)
        l *= 1 - Double(darkness * factor)
        let rgb = HueSaturationFilter.toRGB(hue: h, saturation: s, lightness: l)
        return PaletteColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue))
    }
}

nonisolated struct BrushColorDynamics: Codable, Equatable, Hashable, Sendable {
    var secondaryColor = PaletteColor.white
    var stroke = BrushColorResponse()
    var stamp = BrushColorResponse()
    var pressure = BrushColorResponse()
    var tilt = BrushColorResponse()
    var rotation = BrushColorResponse()
    var isActive: Bool { [stroke, stamp, pressure, tilt, rotation].contains { $0.isActive } }
    var isValid: Bool {
        secondaryColor.isValid && [stroke, stamp, pressure, tilt, rotation].allSatisfy(\.isValid)
            && [stroke, stamp].allSatisfy { $0.hue >= 0 && $0.saturation >= 0 }
    }
    /// Pickup precedes color responses. Stroke randomness is resolved once by BrushStroke.
    func color(_ pigment: SIMD3<Float>, stroke response: BrushColorResponse, input: BrushInput,
               curve: PressureCurve, seed: UInt64, index: Int, copy: Int) -> SIMD3<Float> {
        var color = PaletteColor(red: CGFloat(pigment.x), green: CGFloat(pigment.y), blue: CGFloat(pigment.z))
        color = response.applying(to: color, secondaryColor: secondaryColor)
        color = stamp.randomized(seed: seed, index: index * 16 + copy, channel: 1400).applying(to: color, secondaryColor: secondaryColor)
        if input.pressure != nil {
            color = pressure.applying(to: color, secondaryColor: secondaryColor, factor: StrokePathSettings.Input.pressure.factor(input, curve: curve))
        }
        if input.tilt != nil {
            color = tilt.applying(to: color, secondaryColor: secondaryColor, factor: StrokePathSettings.Input.tilt.factor(input, curve: curve))
        }
        if input.rotation != nil {
            color = rotation.applying(to: color, secondaryColor: secondaryColor, factor: StrokePathSettings.Input.rotation.factor(input, curve: curve))
        }
        return SIMD3(Float(color.red), Float(color.green), Float(color.blue))
    }
}
