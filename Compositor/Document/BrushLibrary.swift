import AppKit
import Observation
import CryptoKit

nonisolated enum BasicBrushShape: String, Codable, CaseIterable, Sendable {
    case hard = "Brush-Preset-Hard.png"
    case soft = "Brush-Preset-Soft.png"
    case medium = "Brush-Preset-Medium.png"
    case mediumHard = "Brush-Preset-Medium-Hard.png"
    case ultraSoft = "Brush-Preset-Ultra-Soft.jpg"

    var generatedTip: GeneratedBrushTip {
        switch self {
        case .hard: .hardRound
        case .soft: .softRound
        case .medium: .mediumRound
        case .mediumHard: .mediumHardRound
        case .ultraSoft: .ultraSoftRound
        }
    }
    static let revision = 2
    var title: String { generatedTip.rawValue }
}

nonisolated enum BrushAssetResolution: Codable, Equatable, Hashable, Sendable {
    case embedded(path: String)
    case procedural(BasicBrushShape, revision: Int)
    case missing
    case cataloguedMissing

    var summary: String {
        switch self {
        case .embedded(let path): "Embedded: \(path) · Original retained"
        case .procedural(let shape, let revision): "\(shape.title) · Approximation · Mapping revision \(revision)"
        case .missing: "Missing reference · Original image unavailable"
        case .cataloguedMissing: "Catalogued name · Original image not supplied"
        }
    }
}

/// Original container bytes live once in the library's source folder, addressed by their SHA-256.
/// Paths and references are provenance, never filesystem paths to open without importer validation.
nonisolated struct BrushSource: Codable, Equatable, Hashable, Sendable {
    struct Definition: Codable, Equatable, Hashable, Sendable {
        var path: String
        var shapeReference: String?
        var grainReference: String?
        var shapeResolution: BrushAssetResolution?
        var grainResolution: BrushAssetResolution?
        var tip: BrushShapeTip? = nil
        var grainTip: BrushShapeTip? = nil
        var basicShape: BasicBrushShape? {
            guard case .procedural(let shape, let revision) = shapeResolution,
                  (1...BasicBrushShape.revision).contains(revision), shape.rawValue == shapeReference else { return nil }
            return shape
        }
        var nativeTip: BrushShapeTip? {
            if let basicShape { return basicShape.generatedTip.make() }
            return ownedTip(reference: shapeReference, resolution: shapeResolution, image: tip)
        }
        var nativeGrainTip: BrushShapeTip? { ownedTip(reference: grainReference, resolution: grainResolution, image: grainTip) }
        private func ownedTip(reference: String?, resolution: BrushAssetResolution?, image: BrushShapeTip?) -> BrushShapeTip? {
            guard case .embedded(let path) = resolution, let reference, BrushZIP.safePath(reference) else { return nil }
            let owner = (self.path as NSString).deletingLastPathComponent
            guard path == (owner.isEmpty ? reference : owner + "/" + reference), image?.isValid == true else { return nil }
            return image
        }

    }
    var archiveDigest: String
    var filename: String
    /// Primary first, followed by any dual components; reset data stays in the original container.
    var definitions: [Definition]
    var memberPath: String? = nil
    var collectionName: String? = nil
    var issues: [String]? = nil

    var isValid: Bool {
        archiveDigest.count == 64 && archiveDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && !filename.isEmpty && filename.utf8.count <= 4096 && !definitions.isEmpty && definitions.count <= 128
            && (memberPath?.utf8.count ?? 0) <= 4096 && (collectionName?.utf8.count ?? 0) <= 4096
            && (issues?.count ?? 0) <= 512 && (issues?.allSatisfy { $0.utf8.count <= 8192 } ?? true)
            && definitions.allSatisfy { !$0.path.isEmpty && $0.path.utf8.count <= 4096
                && ($0.shapeReference?.utf8.count ?? 0) <= 4096 && ($0.grainReference?.utf8.count ?? 0) <= 4096 && ($0.tip?.isValid ?? true) && ($0.grainTip?.isValid ?? true) }
    }
}

/// Only preset-owned settings are saved; color, masks, healing and clone state stay with their tools.
nonisolated struct BrushPreset: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var diameter: CGFloat = 40
    var hardness: CGFloat = 1
    var opacity: CGFloat = 1
    var smoothing: CGFloat = 0
    var pressureSize = false
    var pressureOpacity = false
    var roundDynamics = RoundBrushDynamics()
    var source: BrushSource?
    /// Explicit opt-in; native values remain independent of retained source settings and mapping revisions.
    var usesRoundApproximation = false
    var usesShapeApproximation = false

    var canApproximateRound: Bool {
        guard let source, source.definitions.count == 1, let definition = source.definitions.first,
              definition.grainReference == nil,
              case .procedural(let shape, let revision) = definition.shapeResolution,
              (1...BasicBrushShape.revision).contains(revision), shape.rawValue == definition.shapeReference else { return false }
        return true
    }
    private var primaryShapeSupported: Bool {
        guard let definition = source?.definitions.first else { return source == nil }
        switch roundDynamics.shapeSettings.source {
        case .procedural: return definition.basicShape != nil
        case .generated: return true
        case .embedded:
            guard case .embedded = definition.shapeResolution else { return false }
            return definition.nativeTip != nil
        case .custom: return roundDynamics.shapeSettings.customTip?.isValid == true
        }
    }
    var canConfigureRendering: Bool {
        guard let source else { return true }
        return (1...2).contains(source.definitions.count) && source.definitions.dropFirst().allSatisfy { $0.grainReference == nil } && primaryShapeSupported
            && (source.definitions.first?.grainReference == nil || (roundDynamics.grain != nil
                && (roundDynamics.grain?.source != .original || source.definitions.first?.nativeGrainTip != nil)))
    }
    var canApproximateShape: Bool {
        guard let source, canConfigureRendering else { return false }
        let rendering = roundDynamics.renderingSettings
        if source.definitions.count == 2 && rendering.dualSource == nil { return false }
        return rendering.dualSource != .original || source.definitions.dropFirst().first?.nativeTip != nil
    }
    var isRenderable: Bool { source == nil || (usesRoundApproximation && canApproximateRound)
        || (usesShapeApproximation && canApproximateShape) }

    enum CodingKeys: String, CodingKey {
        case id, name, diameter, hardness, opacity, smoothing, pressureSize, pressureOpacity, source, usesRoundApproximation, roundDynamics, usesShapeApproximation
    }
    init(name: String, hardness: CGFloat = 1) {
        self.name = name
        self.hardness = hardness
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let defaults = BrushSettings()
        diameter = try values.decodeIfPresent(CGFloat.self, forKey: .diameter) ?? defaults.diameter
        hardness = try values.decodeIfPresent(CGFloat.self, forKey: .hardness) ?? defaults.hardness
        opacity = try values.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? defaults.opacity
        smoothing = try values.decodeIfPresent(CGFloat.self, forKey: .smoothing) ?? defaults.smoothing
        pressureSize = try values.decodeIfPresent(Bool.self, forKey: .pressureSize) ?? defaults.pressureSize
        pressureOpacity = try values.decodeIfPresent(Bool.self, forKey: .pressureOpacity) ?? defaults.pressureOpacity
        roundDynamics = try values.decodeIfPresent(RoundBrushDynamics.self, forKey: .roundDynamics) ?? RoundBrushDynamics()
        source = try values.decodeIfPresent(BrushSource.self, forKey: .source)
        usesRoundApproximation = try values.decodeIfPresent(Bool.self, forKey: .usesRoundApproximation) ?? false
        usesShapeApproximation = try values.decodeIfPresent(Bool.self, forKey: .usesShapeApproximation) ?? false
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200
            && diameter.isFinite && (1...2000).contains(diameter)
            && hardness.isFinite && (0...1).contains(hardness)
            && opacity.isFinite && (0.01...1).contains(opacity)
            && smoothing.isFinite && (0...100).contains(smoothing) && (source?.isValid ?? true) && roundDynamics.isValid
            && (roundDynamics.shapeSettings.source != .embedded || source?.definitions.first?.tip?.isValid == true)
            && (roundDynamics.grain?.source != .original || source?.definitions.first?.nativeGrainTip != nil)
            && (roundDynamics.renderingSettings.dualSource != .original || source?.definitions.dropFirst().first?.nativeTip != nil)
    }
    func applying(to settings: BrushSettings) -> BrushSettings {
        guard isRenderable else { return settings }
        var result = settings
        result.diameter = diameter; result.hardness = hardness; result.opacity = opacity
        result.grainTip = source?.definitions.first?.nativeGrainTip
        result.secondaryShapeTip = roundDynamics.renderingSettings.dualSource == .original ? source?.definitions.dropFirst().first?.nativeTip : nil
        result.smoothing = smoothing; result.pressureSize = pressureSize; result.pressureOpacity = pressureOpacity; result.roundDynamics = roundDynamics
        switch roundDynamics.shapeSettings.source {
        case .procedural: result.shapeTip = nil
        case .generated: result.shapeTip = nil
        case .custom: result.shapeTip = roundDynamics.shapeSettings.customTip
        case .embedded: result.shapeTip = source?.definitions.first?.tip
        }
        return result
    }
    mutating func capture(_ settings: BrushSettings) {
        diameter = settings.diameter; hardness = settings.hardness; opacity = settings.opacity
        smoothing = settings.smoothing; pressureSize = settings.pressureSize; pressureOpacity = settings.pressureOpacity; roundDynamics = settings.roundDynamics
    }
}

@MainActor @Observable
final class BrushLibrary {
    static let shared = BrushLibrary(url: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Compositor/brushes.json") : nil)
    private(set) var brushes = [BrushPreset(name: "Hard Round"), BrushPreset(name: "Soft Round", hardness: 0)]
    private(set) var selectedID: UUID?
    private(set) var error: String?
    private let url: URL?

    private struct Collection: Codable {
        var version = 1
        var brushes: [BrushPreset]
        var selectedID: UUID?
    }
    init(url: URL?) {
        self.url = url
        // A saved collection owns its edits and deletions; bundled presets seed new collections only.
        let saved = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let collectionURL = saved ?? Bundle.main.url(forResource: "DefaultBrushes", withExtension: "json") else { return }
        do {
            guard try collectionURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 8 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: collectionURL, options: .mappedIfSafe)
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let collection = try JSONDecoder().decode(Collection.self, from: data)
            guard collection.version == 1, !collection.brushes.isEmpty, collection.brushes.count <= 1000,
                  collection.brushes.allSatisfy(\.isValid), Set(collection.brushes.map(\.id)).count == collection.brushes.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            brushes = collection.brushes
            selectedID = brushes.contains { $0.id == collection.selectedID } ? collection.selectedID : brushes.first?.id
        } catch { self.error = "Couldn’t read the brush collection. The saved file has been left unchanged. \(error.localizedDescription)" }
    }
    /// Called by the importer before publishing presets. The source file is immutable and shared by digest.
    func retainSource(_ data: Data) throws -> String {
        guard error == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard !data.isEmpty, data.count <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = try sourceURL(digest)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file, options: .mappedIfSafe) == data else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return digest
    }
    func sourceData(for source: BrushSource) throws -> Data {
        guard source.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return try retainedData(source.archiveDigest)
    }
    func retainedData(_ digest: String) throws -> Data {
        let file = try sourceURL(digest)
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 512 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    private func sourceURL(_ digest: String) throws -> URL {
        guard let url, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url.deletingPathExtension().appendingPathExtension("sources").appendingPathComponent(digest)
    }
    var current: BrushPreset { brushes.first { $0.id == selectedID } ?? brushes[0] }

    func save(_ brush: BrushPreset, select: Bool = true) throws {
        guard error == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard brush.isValid else { throw CocoaError(.validationMissingMandatoryProperty) }
        var updated = brushes
        if let index = updated.firstIndex(where: { $0.id == brush.id }) { updated[index] = brush }
        else {
            guard updated.count < 1000 else { throw CocoaError(.fileWriteOutOfSpace) }
            updated.append(brush)
        }
        if let source = brush.source { _ = try sourceData(for: source) }
        if let digest = brush.roundDynamics.shapeSettings.customTip?.originalDigest { _ = try retainedData(digest) }
        try persist(updated, selectedID: select ? brush.id : selectedID)
    }

    func delete(_ ids: Set<UUID>) throws {
        guard error == nil else { throw CocoaError(.fileReadCorruptFile) }
        guard brushes.contains(where: { ids.contains($0.id) }) else { return }
        var updated = brushes.filter { !ids.contains($0.id) }
        // Keep a usable brush even when the last native preset is deleted.
        if !updated.contains(where: { $0.source == nil }) { updated.append(BrushPreset(name: "Hard Round")) }
        let selection = updated.first { $0.id == selectedID && $0.source == nil } ?? updated.first { $0.source == nil }!
        try persist(updated, selectedID: selection.id)
    }

    /// Publish an entire validated import once. Reimport never overwrites native edits or changes selection.
    func importBrushes(_ result: ProcreateBrushImporter.Result, original: Data) throws -> Int {
        guard error == nil, !result.brushes.isEmpty, result.brushes.allSatisfy(\.isValid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        guard result.brushes.allSatisfy({ $0.source?.archiveDigest == digest }) else { throw CocoaError(.fileReadCorruptFile) }
        var updated = brushes
        for brush in result.brushes {
            let existing = updated.contains {
                $0.source?.archiveDigest == digest && $0.source?.memberPath == brush.source?.memberPath
                    && $0.source?.definitions.first?.path == brush.source?.definitions.first?.path
            }
            if !existing { updated.append(brush) }
        }
        guard updated.count <= 1000, Set(updated.map(\.id)).count == updated.count else { throw CocoaError(.fileWriteOutOfSpace) }
        let added = updated.count - brushes.count
        if added > 0 {
            _ = try retainSource(original)
            try persist(updated, selectedID: selectedID)
        }
        return added
    }
    private func persist(_ updated: [BrushPreset], selectedID: UUID?) throws {
        if let url {
            let data = try JSONEncoder().encode(Collection(brushes: updated, selectedID: selectedID))
            guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        brushes = updated
        self.selectedID = selectedID
    }
}

extension EditorSession {
    func deleteBrushPresets(_ ids: Set<UUID>, library: BrushLibrary? = nil) throws {
        let library = library ?? .shared
        guard finishBrushImmediately() else { throw CocoaError(.userCancelled) }
        try library.delete(ids)
        if !library.brushes.contains(where: { $0.id == selectedBrushPresetID }) {
            brushSettings = library.current.applying(to: brushSettings)
            selectedBrushPresetID = library.current.id
        }
    }

    /// Selection and editor Save share the same persistence and tool-context boundary.
    func activateBrushPreset(_ preset: BrushPreset, library: BrushLibrary? = nil) throws {
        let library = library ?? .shared
        // Retaining source data is not a renderer mapping. Imported presets remain inspection-only for now.
        guard preset.isRenderable else { throw CocoaError(.featureUnsupported) }
        guard finishBrushImmediately() else { throw CocoaError(.userCancelled) }
        try library.save(preset)
        brushSettings = preset.applying(to: brushSettings)
        selectedBrushPresetID = preset.id
    }

    var activeBrushPreset: BrushPreset? {
        guard var preset = BrushLibrary.shared.brushes.first(where: { $0.id == selectedBrushPresetID }) else { return nil }
        preset.capture(brushSettings)
        return preset
    }
    func persistActiveBrushSettings(library: BrushLibrary? = nil) throws {
        // UI tests use explicit libraries; incidental header updates must not change other tests' defaults.
        guard library != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let library = library ?? .shared
        guard tool == .brush, var preset = library.brushes.first(where: { $0.id == selectedBrushPresetID }) else { return }
        let original = preset
        preset.capture(brushSettings)
        if preset != original { try library.save(preset) }
    }
}
