import Foundation

nonisolated extension CameraRawSettings {
    /// These settings as a preset stores them: a JSON object, without the Geometry guide lines, which belong to
    /// the image they were drawn on, or the point colors' Visualize switches, which are a view of the panel.
    var presetObject: Any {
        let settings = normalized.forPreset
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }
        return object
    }

    /// Settings read back from a preset. The saved object is laid over the defaults first, so a preset saved before a
    /// slider existed takes that slider's default, and fields this build doesn't know are ignored. Values are clamped
    /// to their ranges. Nil when the object still can't be read (not an object, or a choice this build lacks).
    static func preset(from object: Any) -> CameraRawSettings? {
        guard var saved = object as? [String: Any], let defaults = CameraRawSettings().presetObject as? [String: Any],
              JSONSerialization.isValidJSONObject(saved) else { return nil }
        // List entries have defaults too: each point color is laid over a new one.
        if var mixer = saved["mixer"] as? [String: Any], let points = mixer["points"] as? [Any],
           let blank = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraRawPointColor()))) as? [String: Any] {
            mixer["points"] = points.map { ($0 as? [String: Any]).map { merged($0, over: blank) } ?? $0 }
            saved["mixer"] = mixer
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged(saved, over: defaults)),
              var settings = try? JSONDecoder().decode(CameraRawSettings.self, from: data).forPreset else { return nil }
        // The mixer's kernel reads exactly eight families from each list.
        func eight(_ values: [Double]) -> [Double] { Array((values + Array(repeating: 0, count: 8)).prefix(8)) }
        settings.mixer.hue = eight(settings.mixer.hue)
        settings.mixer.saturation = eight(settings.mixer.saturation)
        settings.mixer.luminance = eight(settings.mixer.luminance)
        return settings.normalized
    }

    /// What of these settings a preset keeps.
    var forPreset: Self {
        var result = self
        result.geometry.guides = []
        for index in result.mixer.points.indices { result.mixer.points[index].visualize = false }
        return result
    }

    private static func merged(_ saved: [String: Any], over defaults: [String: Any]) -> [String: Any] {
        var result = defaults
        for (key, value) in saved {
            if let inner = value as? [String: Any], let base = defaults[key] as? [String: Any] {
                result[key] = merged(inner, over: base)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// A person's saved Camera Raw look, by name.
struct CameraRawPreset: Identifiable, Equatable {
    let name: String
    let settings: CameraRawSettings
    var id: String { name }
}

nonisolated enum CameraRawPresetError: LocalizedError, Equatable {
    case invalidName
    case nameTaken(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .invalidName: return "A preset needs a name of 1 to \(CameraRawPresetStore.nameLimit) characters."
        case .nameTaken(let name): return "There's already a preset called “\(name)”."
        case .missing(let name): return "There's no preset called “\(name)”."
        }
    }
}

/// The person's Camera Raw presets. They belong to the app, not to a project: one JSON file in Application Support,
/// `{"version": 1, "presets": [{"name": …, "settings": {…}}]}`. A preset this build can't read is left out of the
/// list but written back as it was; a file that can't be read at all is set aside as `.bak` before it is replaced.
@MainActor @Observable
final class CameraRawPresetStore {
    static let shared = CameraRawPresetStore(url: URL.applicationSupportDirectory.appending(path: "CameraRawPresets.json"))
    nonisolated static let nameLimit = 64

    let url: URL
    /// Sorted by name, ignoring case.
    private(set) var presets: [CameraRawPreset] = []
    @ObservationIgnored private var unreadable: [[String: Any]] = []
    @ObservationIgnored private var fileIsUnreadable = false

    init(url: URL) {
        self.url = url
        reload()
    }

    /// `name` trimmed, or nil when that leaves nothing or more than `nameLimit` characters.
    static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...nameLimit).contains(trimmed.count) ? trimmed : nil
    }

    func preset(named name: String) -> CameraRawPreset? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func reload() {
        presets = []
        unreadable = []
        fileIsUnreadable = false
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = file["presets"] as? [Any] else { fileIsUnreadable = true; return }
        var read: [CameraRawPreset] = []
        for case let entry as [String: Any] in entries {
            if let name = (entry["name"] as? String).flatMap(Self.validName),
               let settings = entry["settings"].flatMap(CameraRawSettings.preset(from:)),
               !read.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                read.append(CameraRawPreset(name: name, settings: settings))
            } else {
                unreadable.append(entry)
            }
        }
        presets = Self.sorted(read)
    }

    /// Saves `settings` as `name`, replacing a preset of that name (ignoring case).
    func save(_ settings: CameraRawSettings, as name: String) throws {
        guard let name = Self.validName(name) else { throw CameraRawPresetError.invalidName }
        var list = presets.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        list.append(CameraRawPreset(name: name, settings: CameraRawSettings.preset(from: settings.presetObject) ?? settings))
        try write(list, unreadable: unreadable.filter { !Self.named($0, name) })
    }

    func rename(_ name: String, to newName: String) throws {
        guard let newName = Self.validName(newName) else { throw CameraRawPresetError.invalidName }
        guard let preset = preset(named: name) else { throw CameraRawPresetError.missing(name) }
        if let other = self.preset(named: newName), other.name != preset.name { throw CameraRawPresetError.nameTaken(other.name) }
        let list = presets.map { $0.name == preset.name ? CameraRawPreset(name: newName, settings: $0.settings) : $0 }
        try write(list, unreadable: unreadable)
    }

    func delete(_ name: String) throws {
        guard let preset = preset(named: name) else { throw CameraRawPresetError.missing(name) }
        try write(presets.filter { $0.name != preset.name }, unreadable: unreadable)
    }

    /// Writes the file first and only then takes the new list, so a failed write leaves both as they were.
    private func write(_ list: [CameraRawPreset], unreadable kept: [[String: Any]]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileIsUnreadable, manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try manager.moveItem(at: url, to: backup)
        }
        let entries: [[String: Any]] = list.map { ["name": $0.name, "settings": $0.settings.presetObject] } + kept
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": entries],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        fileIsUnreadable = false
        unreadable = kept
        presets = Self.sorted(list)
    }

    private static func sorted(_ list: [CameraRawPreset]) -> [CameraRawPreset] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func named(_ entry: [String: Any], _ name: String) -> Bool {
        (entry["name"] as? String).flatMap(validName)?.caseInsensitiveCompare(name) == .orderedSame
    }
}

extension EditorSession {
    /// The open Camera Raw panel's sliders as Save Settings as Preset keeps them. Nil when Camera Raw isn't open.
    var cameraRawPresetSettings: CameraRawSettings? {
        guard let edit = filterEdit, edit.kind == .cameraRaw else { return nil }
        return edit.settings.cameraRaw.forPreset
    }

    /// Sets every Camera Raw slider to `preset`. Cancel still takes it all back. A preset saved with White Balance >
    /// Auto balances this image again, as Camera Raw does.
    func applyCameraRawPreset(_ preset: CameraRawPreset) async {
        guard let edit = filterEdit, edit.kind == .cameraRaw, !edit.committing else { return }
        var settings = edit.settings
        settings.cameraRaw = preset.settings
        updateFilter(settings, preview: edit.preview)
        if preset.settings.whiteBalance == .auto { await applyCameraRawAutoWhiteBalance() }
    }
}
