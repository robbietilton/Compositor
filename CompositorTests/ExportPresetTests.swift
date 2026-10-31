import Foundation
import Testing
@testable import Compositor

struct ExportPresetTests {
    private func preset(edge: Int? = nil) -> ExportPreset {
        ExportPreset(name: "Web", format: .jpeg, longestEdge: edge,
                     quality: 0.85, red: 1, green: 0.5, blue: 0)
    }

    @Test func longestEdgeFitsEitherOrientationWithoutUpscaling() {
        let saved = preset(edge: 1600)
        #expect(saved.scale(width: 4000, height: 3000) == 0.4)
        #expect(saved.scale(width: 3000, height: 4000) == 0.4)
        #expect(saved.scale(width: 800, height: 600) == 1)
        #expect(preset().scale(width: 4000, height: 3000) == 1)
        #expect(preset(edge: 100).scale(width: 30_000, height: 20_000) == 1.0 / 300)
    }

    @Test func presetsPersistAndDeleteAcrossLoads() throws {
        let suite = "ExportPresetTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = preset(edge: 1600)
        try ExportPresetStore.save([saved], to: defaults)
        #expect(ExportPresetStore.load(from: defaults) == [saved])
        try ExportPresetStore.save([], to: defaults)
        #expect(ExportPresetStore.load(from: defaults).isEmpty)
    }

    @Test func invalidAndCorruptPreferencesAreIgnored() throws {
        let suite = "ExportPresetTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid JSON".utf8), forKey: ExportPresetStore.key)
        #expect(ExportPresetStore.load(from: defaults).isEmpty)
        var invalid = preset(edge: 0)
        #expect(!invalid.isValid)
        invalid = preset()
        invalid.quality = 1.1
        #expect(!invalid.isValid)
        invalid = preset()
        invalid.name = "  \n"
        #expect(!invalid.isValid)
        try ExportPresetStore.save([preset(), invalid], to: defaults)
        #expect(ExportPresetStore.load(from: defaults).count == 1)
    }
}
