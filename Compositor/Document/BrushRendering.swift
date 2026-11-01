import AppKit

nonisolated struct BrushRenderingSettings: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case standard = "Standard", lightGlaze = "Light Glaze", uniformGlaze = "Uniform Glaze"
        case intenseGlaze = "Intense Glaze", heavyGlaze = "Heavy Glaze"
        case uniformBlending = "Uniform Blending", intenseBlending = "Intense Blending"
        var index: Int32 { Int32(Self.allCases.firstIndex(of: self)!) }
        var pickup: Float { self == .uniformBlending ? 0.35 : self == .intenseBlending ? 0.65 : 0 }
    }
    enum DualSource: String, Codable, CaseIterable, Sendable { case generated = "Native Secondary Tip", original = "Original Secondary Tip" }
    var mode: Mode = .standard
    var wetEdges: CGFloat = 0
    var burntEdges: CGFloat = 0
    var edgeBlend: LayerBlendMode = .multiply
    var strokeBlend: LayerBlendMode = .normal
    var luminanceBlending = false
    var alphaThreshold: CGFloat? = nil
    var dualSource: DualSource? = nil
    var secondary: GeneratedBrushTip = .softRound
    var secondaryScale: CGFloat = 1
    var classicDualNormal = false
    var isActive: Bool {
        mode != .standard || wetEdges > 0 || burntEdges > 0 || strokeBlend != .normal
            || luminanceBlending || alphaThreshold != nil || dualSource != nil
    }
    var isValid: Bool {
        [wetEdges, burntEdges].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && (alphaThreshold.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && secondaryScale.isFinite && (0.1...2).contains(secondaryScale)
    }
}
