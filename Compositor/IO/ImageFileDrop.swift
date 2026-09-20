import SwiftUI
import UniformTypeIdentifiers

/// Resolve in pasteboard order; the importer validates contents rather than trusting extensions.
@MainActor
enum ImageFileDrop {
    static let projectDropTypeIdentifiers = [UTType.fileURL.identifier]
    static let dropTypeIdentifiers = projectDropTypeIdentifiers + [ProjectWorkspace.layerType]

    static func importProviders(_ providers: [NSItemProvider], into session: EditorSession, at point: CGPoint?, projects: ProjectController? = nil, workspace: ProjectWorkspace? = nil, destination: UUID? = nil) async {
        var urls: [URL] = []
        var unreadable = false
        for provider in providers {
            if let url = await fileURL(from: provider) { urls.append(url) }
            // Not a file on disk: a screenshot's thumbnail, or an image dragged from a web page or another app,
            // hands over image data (or a file it only promises). Copy it somewhere the importer can read.
            else if let copy = await temporaryFile(from: provider) { urls.append(copy) }
            else { unreadable = true }
        }
        if let workspace { await workspace.receive(urls, into: destination, at: point) }
        else if let projects { await projects.receive(urls, at: point) }
        else { await session.importImages(urls, at: point) }
        if unreadable, !providers.isEmpty {
            let message = "Some dropped items couldn’t be read. Drag a Compositor project, Photoshop document, or JPEG, PNG, HEIC, or TIFF files from Finder."
            session.importError = [session.importError, message].compactMap { $0 }.joined(separator: "\n\n")
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            let loaded: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    continuation.resume(returning: object)
                }
            }
            if let url = keptFileURL(loaded) { return url }
        }
        for identifier in [UTType.fileURL.identifier, UTType.photoshopDocument.identifier, "com.adobe.photoshop-image"]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            if identifier == UTType.fileURL.identifier {
                let item: Any? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                        continuation.resume(returning: item)
                    }
                }
                if let url = resolvedFileURL(item) { return url }
            }
            if let copy = await copyFileRepresentation(provider, identifier) { return copy }
        }
        return nil
    }

    private static func keptFileURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if url.isFileURL { return url }
        if url.scheme == nil || url.path.hasPrefix("/") { return URL(fileURLWithPath: url.path) }
        return nil
    }

    /// Finder sometimes hands a file-reference URL or UTF-8 data; keep the original file URL.
    private static func resolvedFileURL(_ item: Any?) -> URL? {
        let url: URL?
        if let value = item as? URL { url = value }
        else if let value = item as? NSURL { url = value as URL }
        else if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
                ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let path = item as? String { url = URL(fileURLWithPath: path) }
        else { url = nil }
        return keptFileURL(url)
    }

    private static func copyFileRepresentation(_ provider: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = url.deletingPathExtension().lastPathComponent
                let suffix = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "psd") : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name.isEmpty ? "Dropped" : name)-\(UUID().uuidString)")
                    .appendingPathExtension(suffix)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }

    /// A dropped item's image written to a temporary file, or nil when it holds no image.
    private static func temporaryFile(from provider: NSItemProvider) async -> URL? {
        // Prefer the Photoshop file itself over `public.image`, which ImageIO may flatten to PNG/TIFF.
        let types = [UTType.photoshopDocument.identifier, "com.adobe.photoshop-image"]
            + [UTType.png, .jpeg, .heic, .tiff, .image].map(\.identifier)
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            // The file only exists until this closure returns, so it is copied, not referenced.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = url.deletingPathExtension().lastPathComponent
                let suffix = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(name.isEmpty ? "Dropped" : name)-\(UUID().uuidString)")
                    .appendingPathExtension(suffix)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }
}
