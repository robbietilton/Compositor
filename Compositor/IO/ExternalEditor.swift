import AppKit
import Observation
import ImageIO
import UniformTypeIdentifiers

/// An app a layer can be sent to and brought back from, the way Photoshop's Automate plug-ins round-trip a layer
/// through Topaz Gigapixel: Compositor writes the layer's pixels to a file, opens that file in the app, and takes
/// back whatever the app saves beside it.
nonisolated struct ExternalEditorApp: Identifiable, Hashable, Sendable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Apps offered without being chosen first, whenever they are installed. Topaz renamed its bundles over the
    /// years, so each app is listed under every identifier it has shipped with.
    static let presetBundleIDs = [
        "com.topazlabs.TopazGigapixelAI", "com.topazlabs.TopazGigapixel", "com.topazlabs.Topaz Gigapixel AI",
        "com.topazlabs.TopazPhotoAI", "com.topazlabs.Topaz Photo AI",
    ]

    /// The presets that are installed, then the apps the person picked with Other App…, each once.
    static func available() -> [ExternalEditorApp] {
        let presets = presetBundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        var seen = Set<String>()
        return (presets + chosen()).map { ExternalEditorApp(url: $0.standardizedFileURL) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) && seen.insert($0.url.path).inserted }
    }

    private static let chosenKey = "externalEditor.apps"
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static func chosen() -> [URL] {
        guard !isTesting else { return [] }
        return (UserDefaults.standard.stringArray(forKey: chosenKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Remembers an app picked with Other App…, most recent first, so it is listed next time.
    static func remember(_ app: ExternalEditorApp) {
        guard !isTesting else { return }
        let paths = [app.url.path] + chosen().map(\.path).filter { $0 != app.url.path }
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: chosenKey)
    }
}

/// The folder layers are written to for an external app, and where its result is looked for.
///
/// It is one the person chooses once, not Compositor's own temporary folder: that lives inside the sandbox
/// container, and since macOS 14 another app reaching into it asks the person for permission first. The choice
/// is kept as a security-scoped bookmark, so it survives relaunches.
enum ExternalEditFolder {
    private static let bookmarkKey = "externalEditor.folderBookmark"

    /// The saved folder, or nil when there is none or it has gone.
    static func saved() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    /// Asks for the folder, with `current` (if any) selected.
    static func choose(current: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a Folder for External Edits"
        panel.message = "Layers are saved here for the other app to open. Save its result to the same folder and it comes back to Compositor on its own."
        panel.prompt = "Use Folder"
        panel.directoryURL = current ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }

    private static func remember(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
}

/// Which files in the folder are an app's result for the layer sent out as `source`.
///
/// Apps name what they save after what they opened, adding a suffix, a prefix or both (Gigapixel appends
/// "-gigapixel" and the model by default, and either is configurable), and may change the format. The source's
/// name ends in a token unique to that edit, so containing its stem is specific enough.
nonisolated enum ExternalEditMatch {
    static let resultExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic"]

    static func isResult(_ candidate: URL, for source: URL, startedAt: Date, modified: Date?) -> Bool {
        guard candidate.standardizedFileURL != source.standardizedFileURL,
              resultExtensions.contains(candidate.pathExtension.lowercased()),
              candidate.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(
                  source.deletingPathExtension().lastPathComponent) else { return false }
        // File systems round modification dates; allow a second either way.
        guard let modified else { return true }
        return modified >= startedAt.addingTimeInterval(-1)
    }

    /// A file name for sending `layerName` out: its name made safe for a path, then a short unique token.
    static func sourceName(for layerName: String, token: UUID = UUID()) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(layerName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? "Layer" : String(cleaned.prefix(60))
        return "\(stem) \(token.uuidString.prefix(8)).png"
    }
}

nonisolated enum ExternalEditError: LocalizedError {
    case write, launch(String)
    var errorDescription: String? {
        switch self {
        case .write: "The layer couldn’t be saved to the external edits folder. Check that the folder still exists and can be written to."
        case .launch(let name): "\(name) couldn’t be opened."
        }
    }
}

/// Writing the layer out, opening it in the app, and waiting for the result.
nonisolated enum ExternalEditBridge {
    /// Saves `image` as a PNG at `url`, keeping its transparency.
    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ExternalEditError.write }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExternalEditError.write }
    }

    @MainActor static func open(_ file: URL, in app: ExternalEditorApp) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do { _ = try await NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: configuration) }
        catch { throw ExternalEditError.launch(app.name) }
    }

    /// Polls `folder` until a result for `source` appears and has finished being written: its size is the same
    /// on two looks in a row and ImageIO can read the whole image. Returns nil when cancelled, or as soon as
    /// `shouldContinue` says the edit is no longer wanted (its project was closed, say).
    static func waitForResult(in folder: URL, for source: URL, startedAt: Date, interval: Duration = .seconds(1),
                              shouldContinue: @escaping @Sendable () async -> Bool = { true }) async -> URL? {
        var sizes: [URL: Int] = [:]
        while !Task.isCancelled, await shouldContinue() {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])) ?? []
            var seen: [URL: Int] = [:]
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      ExternalEditMatch.isResult(file, for: source, startedAt: startedAt, modified: values.contentModificationDate),
                      let size = values.fileSize, size > 0 else { continue }
                seen[file] = size
                if sizes[file] == size, isComplete(file) { return file }
            }
            sizes = seen
            try? await Task.sleep(for: interval)
        }
        return nil
    }

    private static func isComplete(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete && CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
}

/// How results come back from external apps, as the person last set it in the Edit in External App menu.
@Observable
final class ExternalEditSettings {
    static let shared = ExternalEditSettings()
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var keepsOriginal: Bool { didSet { save(keepsOriginal, "externalEditor.keepsOriginal") } }
    var enlargesCanvas: Bool { didSet { save(enlargesCanvas, "externalEditor.enlargesCanvas") } }
    var options: ExternalEditOptions { ExternalEditOptions(keepsOriginal: keepsOriginal, enlargesCanvas: enlargesCanvas) }

    private init() {
        let defaults = UserDefaults.standard
        keepsOriginal = Self.isTesting ? true : defaults.object(forKey: "externalEditor.keepsOriginal") as? Bool ?? true
        enlargesCanvas = Self.isTesting ? true : defaults.object(forKey: "externalEditor.enlargesCanvas") as? Bool ?? true
    }

    private func save(_ value: Bool, _ key: String) {
        guard !Self.isTesting else { return }
        UserDefaults.standard.set(value, forKey: key)
    }
}
