import Foundation

/// Independently authored physical-style masks. No source-image pixels or downloads are stored.
nonisolated enum GeneratedBrushTip: String, Codable, CaseIterable, Hashable, Sendable {
    case ultraSoftRound = "Ultra Soft Round", softRound = "Soft Round", mediumRound = "Medium Round"
    case mediumHardRound = "Medium Hard Round", hardRound = "Hard Round"
    case ink = "Ink Dab"
    case bristles = "Dry Bristles"
    case speckle = "Speckle"

    private static let cache = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.build()) })
    func make() -> BrushShapeTip { Self.cache[self]! }

    private static func roundCoverage(_ r: CGFloat, core: CGFloat, edge: CGFloat, exponent: CGFloat) -> CGFloat {
        let t = min(1, max(0, (r - core) / (edge - core)))
        let rim = exp(-exponent)
        return max(0, (exp(-exponent * t * t) - rim) / (1 - rim))
    }

    private func build() -> BrushShapeTip {
        let side = 128
        var pixels = Data(count: side * side)
        for y in 0..<side { for x in 0..<side {
            let u = (CGFloat(x) + 0.5) / CGFloat(side) * 2 - 1
            let v = (CGFloat(y) + 0.5) / CGFloat(side) * 2 - 1
            let r = hypot(u, v)
            let value: CGFloat
            switch self {
            case .ultraSoftRound:
                value = Self.roundCoverage(r, core: 0, edge: 0.9, exponent: 2.5) * 0.45
            case .softRound:
                value = Self.roundCoverage(r, core: 0, edge: 1, exponent: 2.2)
            case .mediumRound:
                value = Self.roundCoverage(r, core: 0.45, edge: 1, exponent: 5)
            case .mediumHardRound:
                value = Self.roundCoverage(r, core: 0.7, edge: 1, exponent: 12)
            case .hardRound:
                value = min(1, max(0, (0.8 - r) * CGFloat(side) / 2 + 0.5))
            case .ink:
                let angle = atan2(v, u)
                let edge = 0.82 + 0.07 * sin(angle * 5) + 0.04 * cos(angle * 9)
                value = min(1, max(0, (edge - r) / 0.06))
                    * (0.85 + 0.15 * brushRandomUnit(seed: 17, index: y * side + x, channel: 0))
            case .bristles:
                let strand = pow(abs(sin((u + 1) * 31)), 3)
                let edge = max(0, 1 - pow(abs(u) / 0.85, 8)) * max(0, 1 - pow(abs(v) / 0.9, 6))
                value = strand * edge * (0.55 + 0.45 * brushRandomUnit(seed: 29, index: y * side + x, channel: 1))
            case .speckle:
                let cell = (y / 8) * 16 + x / 8
                let cx = 0.2 + 0.6 * brushRandomUnit(seed: 43, index: cell, channel: 2)
                let cy = 0.2 + 0.6 * brushRandomUnit(seed: 43, index: cell, channel: 3)
                let radius = 0.1 + 0.28 * brushRandomUnit(seed: 43, index: cell, channel: 4)
                let distance = hypot((CGFloat(x % 8) + 0.5) / 8 - cx, (CGFloat(y % 8) + 0.5) / 8 - cy)
                value = min(1, max(0, (radius - distance) * 12)) * min(1, max(0, (0.92 - r) * 8))
            }
            pixels[y * side + x] = UInt8((min(1, max(0, value)) * 255).rounded())
        } }
        return BrushShapeTip(side: side, luminance: pixels, alpha: pixels, name: "Compositor Generated " + rawValue)
    }
}

/// Shared deterministic channels for stroke placement, shape behavior and independent mask generation.
nonisolated func brushRandomUnit(seed: UInt64, index: Int, channel: Int) -> CGFloat {
    var bits = seed &+ UInt64(index) &* 0x9e3779b97f4a7c15 &+ UInt64(channel) &* 0xd1b54a32d192ed03
    bits = (bits ^ (bits >> 30)) &* 0xbf58476d1ce4e5b9
    bits = (bits ^ (bits >> 27)) &* 0x94d049bb133111eb
    bits ^= bits >> 31
    return CGFloat(bits >> 11) / CGFloat(UInt64(1) << 53)
}
