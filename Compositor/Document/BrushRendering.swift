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
    var backruns: CGFloat = 0
    var edgeBlend: LayerBlendMode = .multiply
    var strokeBlend: LayerBlendMode = .normal
    var luminanceBlending = false
    var alphaThreshold: CGFloat? = nil
    var dualSource: DualSource? = nil
    var secondary: GeneratedBrushTip = .softRound
    var secondaryScale: CGFloat = 1
    var classicDualNormal = false
    private enum CodingKeys: String, CodingKey {
        case mode, wetEdges, burntEdges, backruns, edgeBlend, strokeBlend, luminanceBlending
        case alphaThreshold, dualSource, secondary, secondaryScale, classicDualNormal
    }

    init(mode: Mode = .standard, wetEdges: CGFloat = 0, burntEdges: CGFloat = 0, backruns: CGFloat = 0,
         edgeBlend: LayerBlendMode = .multiply, strokeBlend: LayerBlendMode = .normal,
         luminanceBlending: Bool = false, alphaThreshold: CGFloat? = nil, dualSource: DualSource? = nil,
         secondary: GeneratedBrushTip = .softRound, secondaryScale: CGFloat = 1, classicDualNormal: Bool = false) {
        self.mode = mode
        self.wetEdges = wetEdges
        self.burntEdges = burntEdges
        self.backruns = backruns
        self.edgeBlend = edgeBlend
        self.strokeBlend = strokeBlend
        self.luminanceBlending = luminanceBlending
        self.alphaThreshold = alphaThreshold
        self.dualSource = dualSource
        self.secondary = secondary
        self.secondaryScale = secondaryScale
        self.classicDualNormal = classicDualNormal
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .standard
        wetEdges = try values.decodeIfPresent(CGFloat.self, forKey: .wetEdges) ?? 0
        burntEdges = try values.decodeIfPresent(CGFloat.self, forKey: .burntEdges) ?? 0
        backruns = try values.decodeIfPresent(CGFloat.self, forKey: .backruns) ?? 0
        edgeBlend = try values.decodeIfPresent(LayerBlendMode.self, forKey: .edgeBlend) ?? .multiply
        strokeBlend = try values.decodeIfPresent(LayerBlendMode.self, forKey: .strokeBlend) ?? .normal
        luminanceBlending = try values.decodeIfPresent(Bool.self, forKey: .luminanceBlending) ?? false
        alphaThreshold = try values.decodeIfPresent(CGFloat.self, forKey: .alphaThreshold)
        dualSource = try values.decodeIfPresent(DualSource.self, forKey: .dualSource)
        secondary = try values.decodeIfPresent(GeneratedBrushTip.self, forKey: .secondary) ?? .softRound
        secondaryScale = try values.decodeIfPresent(CGFloat.self, forKey: .secondaryScale) ?? 1
        classicDualNormal = try values.decodeIfPresent(Bool.self, forKey: .classicDualNormal) ?? false
    }

    var isActive: Bool {
        mode != .standard || wetEdges > 0 || burntEdges > 0 || backruns > 0 || strokeBlend != .normal
            || luminanceBlending || alphaThreshold != nil || dualSource != nil
    }
    var isValid: Bool {
        [wetEdges, burntEdges, backruns].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && (alphaThreshold.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && secondaryScale.isFinite && (0.1...2).contains(secondaryScale)
    }
}
