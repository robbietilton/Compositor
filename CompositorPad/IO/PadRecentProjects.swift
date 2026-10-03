import Foundation

/// The projects opened lately, newest first, as the Mac's Open Recent lists them.
@MainActor final class PadRecentProjects {
    static let shared = PadRecentProjects()
    private let key = "recentProjects"
    private let limit = 10

    /// The projects that can still be found, newest first.
    var urls: [URL] {
        references.compactMap { Self.resolve($0) }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    func note(_ url: URL) {
        guard let reference = Self.reference(to: url) else { return }
        let others = references.filter { Self.resolve($0)?.standardizedFileURL != url.standardizedFileURL }
        references = Array(([reference] + others).prefix(limit))
    }

    func clear() { references = [] }

    private var references: [Data] {
        get { UserDefaults.standard.array(forKey: key) as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Where `url` is, to find it again after a relaunch. A project in the app's own Documents folder is kept by its
    /// path there: reinstalling or updating the app moves that folder, and saving a project replaces its package, so
    /// a bookmark to it can end up pointing at neither. Anywhere else it's a bookmark, which carries the permission
    /// Files gave to open it, made while the app may read it.
    static func reference(to url: URL, in folder: URL = CompositorDocument.projectsFolder) -> Data? {
        let documents = folder.resolvingSymlinksInPath().path(percentEncoded: false)
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let entry: [String: Any]
        if path.hasPrefix(documents.hasSuffix("/") ? documents : documents + "/") {
            entry = ["documents": String(path.dropFirst(documents.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        } else {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData() else { return nil }
            entry = ["bookmark": bookmark]
        }
        return try? PropertyListSerialization.data(fromPropertyList: entry, format: .binary, options: 0)
    }

    static func resolve(_ reference: Data, in folder: URL = CompositorDocument.projectsFolder) -> URL? {
        let entry = (try? PropertyListSerialization.propertyList(from: reference, format: nil)) as? [String: Any]
        if let relative = entry?["documents"] as? String {
            let url = folder.appending(path: relative, directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        }
        guard let bookmark = entry?["bookmark"] as? Data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
    }
}
