import Foundation
import Observation

/// A saved Render Finish look: every effect's settings, enabled or not.
nonisolated struct RenderFinishPreset: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var settings: RenderFinishSettings
}

/// Built-in starting points for architectural renders, plus the looks the user has saved (kept in user defaults,
/// so they are available in every document).
@MainActor @Observable
final class RenderFinishPresets {
    static let shared = RenderFinishPresets()
    private(set) var saved: [RenderFinishPreset] = []
    private static let storageKey = "renderFinishPresets.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let presets = try? JSONDecoder().decode([RenderFinishPreset].self, from: data) {
            saved = presets
        }
    }

    /// Saves `settings` under `name`, replacing a saved preset of the same name.
    func save(_ settings: RenderFinishSettings, named name: String) {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !title.isEmpty else { return }
        let preset = RenderFinishPreset(id: UUID().uuidString, name: title, settings: settings.normalized)
        if let index = saved.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(title) == .orderedSame }) {
            saved[index].settings = preset.settings
        } else {
            saved.append(preset)
        }
        store()
    }

    func delete(_ preset: RenderFinishPreset) {
        saved.removeAll { $0.id == preset.id }
        store()
    }

    private func store() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static let builtIn: [RenderFinishPreset] = [
        look("natural-interior", "Natural Interior") {
            $0[.tonalContrast] = tonal(45, .balanced, shadows: 20, midtones: 35, highlights: 10, protectHighlights: 35)
            $0[.warmth] = warmth(60, warmth: 12, saturation: 6)
            $0[.vignette] = amount(.vignette, 15)
        },
        look("crisp-exterior", "Crisp Exterior") {
            $0[.tonalContrast] = tonal(45, .standard, shadows: 30, midtones: 45, highlights: 25,
                                       protectShadows: 20, protectHighlights: 25)
            $0[.detailExtractor] = amount(.detailExtractor, 25, radius: 4)
            $0[.proContrast] = amount(.proContrast, 35)
        },
        look("evening-glow", "Evening Glow") {
            $0[.tonalContrast] = tonal(35, .balanced, shadows: 20, midtones: 30, highlights: 10, protectHighlights: 20)
            $0[.bloom] = amount(.bloom, 35, radius: 32)
            $0[.warmth] = warmth(70, warmth: 30, saturation: 5)
            $0[.vignette] = amount(.vignette, 25)
        },
        look("soft-daylight", "Soft Daylight") {
            $0[.tonalContrast] = tonal(30, .fine, shadows: 15, midtones: 25, highlights: 5, protectHighlights: 40)
            $0[.bloom] = amount(.bloom, 15, radius: 20)
            $0[.warmth] = warmth(50, warmth: 6, saturation: 4)
        },
        look("photographic", "Photographic") {
            $0[.tonalContrast] = tonal(35, .standard, shadows: 20, midtones: 35, highlights: 10, protectHighlights: 30)
            $0[.microTexture] = amount(.microTexture, 35, radius: 1)
            $0[.highlightRolloff] = amount(.highlightRolloff, 45, radius: 18)
            $0[.lensSoftness] = amount(.lensSoftness, 30, radius: 4)
            $0[.chromaticAberration] = amount(.chromaticAberration, 100, radius: 1.5)
            $0[.vignette] = amount(.vignette, 18)
            $0[.sensorGrain] = amount(.sensorGrain, 30, radius: 1.5)
        },
        look("carbon-monochrome", "Carbon Monochrome") {
            $0[.tonalContrast] = tonal(40, .standard, shadows: 30, midtones: 45, highlights: 20)
            $0[.ink] = amount(.ink, 100)
            $0[.proContrast] = amount(.proContrast, 45)
            $0[.vignette] = amount(.vignette, 20)
        },
    ]

    private static func look(_ id: String, _ name: String, _ configure: (inout RenderFinishSettings) -> Void) -> RenderFinishPreset {
        var settings = RenderFinishSettings()
        for effect in FinishEffect.allCases { settings[effect].enabled = false }
        configure(&settings)
        return RenderFinishPreset(id: "builtin." + id, name: name, settings: settings.normalized)
    }
    private static func amount(_ effect: FinishEffect, _ amount: Double, radius: Double? = nil) -> FinishParameters {
        var value = effect.defaults
        value.enabled = true
        value.amount = amount
        if let radius { value.radius = radius }
        return value
    }
    private static func tonal(_ amount: Double, _ type: TonalContrastType, shadows: Double, midtones: Double, highlights: Double,
                              protectShadows: Double = 0, protectHighlights: Double = 0) -> FinishParameters {
        var value = Self.amount(.tonalContrast, amount)
        value.contrastType = type
        value.shadows = shadows; value.midtones = midtones; value.highlights = highlights
        value.protectShadows = protectShadows; value.protectHighlights = protectHighlights
        return value
    }
    private static func warmth(_ amount: Double, warmth: Double, saturation: Double) -> FinishParameters {
        var value = Self.amount(.warmth, amount)
        value.shadows = warmth
        value.saturation = saturation
        return value
    }
}
