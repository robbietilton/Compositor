import Foundation

nonisolated struct PressureCurve: Codable, Equatable, Hashable, Sendable {
    struct Point: Codable, Equatable, Hashable, Sendable {
        var x: CGFloat
        var y: CGFloat
        /// Nil uses automatic easing (smooth interior points, straight endpoints); zero joins straight.
        var easing: CGFloat? = nil
    }
    var points: [Point] = [.init(x: 0, y: 0), .init(x: 1, y: 1)]
    enum Profile: String, CaseIterable {
        case linear = "Linear", soft = "Soft", firm = "Firm", sCurve = "S-curve"
        var curve: PressureCurve {
            let middle: [Point] = switch self {
            case .linear: []
            case .soft: [.init(x: 0.25, y: 0.5), .init(x: 0.5, y: 0.75)]
            case .firm: [.init(x: 0.5, y: 0.25), .init(x: 0.75, y: 0.5)]
            case .sCurve: [.init(x: 0.25, y: 0.1), .init(x: 0.75, y: 0.9)]
            }
            return PressureCurve(points: [.init(x: 0, y: 0)] + middle + [.init(x: 1, y: 1)])
        }
    }
    var isValid: Bool {
        (2...16).contains(points.count) && points.first?.x == 0 && points.last?.x == 1
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
                && ($0.easing.map { $0.isFinite && (0...1).contains($0) } ?? true) }
            && zip(points, points.dropFirst()).allSatisfy { $0.0.x < $0.1.x }
    }
    func easing(at index: Int) -> CGFloat { points[index].easing ?? (index == 0 || index == points.count - 1 ? 0 : 1) }
    var isIdentity: Bool {
        points.allSatisfy { $0.x == $0.y } && (points.first?.easing ?? 0) == 0 && (points.last?.easing ?? 0) == 0
    }
    func value(_ pressure: CGFloat) -> CGFloat {
        let pressure = pressure.isFinite ? min(1, max(0, pressure)) : 1
        if isIdentity { return pressure }
        // Shape-preserving cubic Hermite interpolation: shared tangents ease through points;
        // extrema get zero slope without overshoot.
        func slope(_ i: Int) -> CGFloat {
            (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x)
        }
        func tangent(_ i: Int) -> CGFloat {
            if i == 0 || i == points.count - 1 { return 0 }
            let a = slope(i - 1), b = slope(i)
            guard a != 0, b != 0, (a > 0) == (b > 0) else { return 0 }
            let before = points[i].x - points[i - 1].x, after = points[i + 1].x - points[i].x
            let w1 = 2 * after + before, w2 = after + 2 * before
            return (w1 + w2) / (w1 / a + w2 / b)
        }
        for i in points.indices.dropLast() where pressure <= points[i + 1].x {
            let a = points[i], b = points[i + 1], h = b.x - a.x
            let t = (pressure - a.x) / h, t2 = t * t, t3 = t2 * t
            let secant = slope(i)
            let m0 = secant + (tangent(i) - secant) * easing(at: i)
            let m1 = secant + (tangent(i + 1) - secant) * easing(at: i + 1)
            guard m0.isFinite, m1.isFinite else { return a.y + (b.y - a.y) * t }
            let y = (2 * t3 - 3 * t2 + 1) * a.y + (t3 - 2 * t2 + t) * h * m0
                + (-2 * t3 + 3 * t2) * b.y + (t3 - t2) * h * m1
            return min(max(a.y, b.y), max(min(a.y, b.y), y))
        }
        return points.last?.y ?? pressure
    }
}

/// Native procedural-tip controls. Defaults retain the legacy continuous round renderer.
nonisolated struct RoundBrushDynamics: Codable, Equatable, Hashable, Sendable {
    var pressureCurve = PressureCurve()
    var spacing: CGFloat? = nil
    var flow: CGFloat = 1
    var taperStart: CGFloat = 0
    var taperEnd: CGFloat = 0
    var roundness: CGFloat = 1
    var angle: CGFloat = 0
    var count = 1
    var scatter: CGFloat = 0
    var strokePath: StrokePathSettings? = nil
    var path: StrokePathSettings { strokePath ?? StrokePathSettings() }
    var rendering: BrushRenderingSettings? = nil
    var renderingSettings: BrushRenderingSettings { rendering ?? BrushRenderingSettings() }
    var shape: ShapeBrushSettings? = nil
    var shapeSettings: ShapeBrushSettings { shape ?? ShapeBrushSettings() }

    var properties: BrushProperties? = nil
    var stabilization: BrushStabilization? = nil
    var pressureTaper: BrushTaper? = nil
    var touchTaper: BrushTaper? = nil
    var tipAnimation: Bool? = nil
    var classicTaper: Bool? = nil
    var colorDynamics: BrushColorDynamics? = nil
    var wetMix: BrushWetMix? = nil
    var grain: BrushGrain? = nil
    var hasTaper: Bool { taperStart > 0 || taperEnd > 0 || pressureTaper?.isActive == true || touchTaper?.isActive == true }

    var usesStamps: Bool {
        colorDynamics?.isActive == true || wetMix?.isActive == true || grain != nil || properties != nil || renderingSettings.isActive || spacing != nil || flow != 1 || hasTaper || roundness != 1 || count != 1 || path.isActive || shapeSettings.isActive
    }
    var isValid: Bool {
        (colorDynamics?.isValid ?? true) && (wetMix?.isValid ?? true) && (properties?.isValid ?? true) && (stabilization?.isValid ?? true) && (pressureTaper?.isValid ?? true) && (touchTaper?.isValid ?? true) && (grain?.isValid ?? true) && pressureCurve.isValid && renderingSettings.isValid && path.isValid && shapeSettings.isValid && (spacing.map { $0.isFinite && (0...4).contains($0) } ?? true)
            && flow.isFinite && (0...1).contains(flow)
            && taperStart.isFinite && (0...1).contains(taperStart) && taperEnd.isFinite && (0...1).contains(taperEnd)
            && roundness.isFinite && (0.05...1).contains(roundness)
            && angle.isFinite && (-CGFloat.pi...CGFloat.pi).contains(angle)
            && (1...16).contains(count) && scatter.isFinite && (0...CGFloat.pi).contains(scatter)
    }
    func taper(at distance: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 1 }
        let start = taperStart > 0 ? distance / (total * taperStart) : 1
        let end = taperEnd > 0 ? (total - distance) / (total * taperEnd) : 1
        return max(0, min(1, min(start, end)))
    }
}

/// Document-space placement controls; nil on older presets preserves their exact defaults.
nonisolated struct StrokePathSettings: Codable, Equatable, Hashable, Sendable {
    enum Input: String, Codable, CaseIterable, Sendable {
        case none = "None", pressure = "Pressure", tilt = "Tilt", rotation = "Barrel Rotation"
        func factor(_ input: BrushInput, curve: PressureCurve) -> CGFloat {
            switch self {
            case .none: return 1
            case .pressure: return input.pressure.map { curve.value($0) } ?? 1
            case .tilt: return input.tilt.map { min(1, hypot($0.x, $0.y)) } ?? 1
            case .rotation: return input.rotation.map { (1 + sin($0)) / 2 } ?? 1
            }
        }
    }
    var spacingJitter: CGFloat = 0
    var lateralJitter: CGFloat = 0
    var linearJitter: CGFloat = 0
    var falloff: CGFloat = 0
    var speedSpacing: CGFloat = 0
    /// Speed normalization remains adjustable for actual hardware and drawing scale.
    var speedReference: CGFloat = 1000
    var spacingInput: Input = .none
    var lateralInput: Input = .none
    var linearInput: Input = .none
    var isActive: Bool { spacingJitter > 0 || lateralJitter > 0 || linearJitter > 0 || falloff > 0 || speedSpacing > 0 }
    var isValid: Bool {
        [spacingJitter, lateralJitter, linearJitter, falloff, speedSpacing].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && speedReference.isFinite && (1...100000).contains(speedReference)
            && (spacingInput == .none || spacingInput == .pressure)
    }
    func opacity(at distance: CGFloat, diameter: CGFloat) -> CGFloat {
        falloff == 0 ? 1 : max(0, 1 - distance * falloff / (diameter * 20))
    }
}
