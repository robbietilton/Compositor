import Foundation

/// Reusable screen-export settings, independent of any document or printer profile.
nonisolated struct ExportPreset: Codable, Equatable, Identifiable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable {
        case png = "PNG", jpeg = "JPEG", tiff = "TIFF", pdf = "PDF"
    }
    var id = UUID()
    var name: String
    var format: Format
    /// Nil keeps the original size. A limit only reduces images, never enlarges them.
    var longestEdge: Int?
    var quality: Double
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
            && (longestEdge.map { (1...DocumentLimits.maxSide).contains($0) } ?? true)
            && [quality, red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func scale(width: Int, height: Int) -> Double {
        guard let longestEdge, width > 0, height > 0 else { return 1 }
        return min(1, Double(longestEdge) / Double(max(width, height)))
    }
}

nonisolated enum ExportPresetStore {
    static let key = "exportPresets.v1"

    static func load(from defaults: UserDefaults = .standard) -> [ExportPreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return [] }
        return presets.filter(\.isValid)
    }

    static func save(_ presets: [ExportPreset], to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(presets), forKey: key)
    }
}
