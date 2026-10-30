import Foundation
import UniformTypeIdentifiers

/// The files that dropped or picked items stand for, in the order given: the file itself for an item on disk, or else
/// a copy of the image it holds, made where the importer can read it. The importer then checks contents rather than
/// trusting a name. The Mac's drops come through here, and so do the iPad's drops and picks from Photos.
@MainActor
enum ItemProviderFiles {
    /// The files for `providers`, and whether any of them held nothing readable. With `suggestedNames`, a copy is named
    /// after what the item calls itself, as a photo in Photos does, rather than after the file it was copied from.
    static func urls(from providers: [NSItemProvider], suggestedNames: Bool = false) async -> (urls: [URL], unreadable: Bool) {
        var urls: [URL] = []
        var unreadable = false
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                }
            }
            if let url { urls.append(url) }
            // Not a file on disk: a screenshot's thumbnail, or an image dragged from a web page or another app,
            // hands over image data (or a file it only promises). Copy it somewhere the importer can read.
            else if let copy = await temporaryFile(from: provider, name: suggestedNames ? provider.suggestedName.flatMap(baseName) : nil) {
                urls.append(copy)
            }
            else { unreadable = true }
        }
        return (urls, unreadable)
    }

    /// A dropped item's image or PDF written to a temporary file, or nil when it holds neither.
    private static func temporaryFile(from provider: NSItemProvider, name suggested: String?) async -> URL? {
        let types = [UTType.png, .jpeg, .gif, .heic, .heif, .tiff, .webP, .photoshopImage, .photoshopLargeImage, .rawImage, .image, .pdf]
            .map(\.identifier)
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            // The file only exists until this closure returns, so it is copied, not referenced.
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let name = suggested ?? url.deletingPathExtension().lastPathComponent
                let suffix = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "png") : url.pathExtension
                // A unique folder rather than a unique file name: the copy keeps the name the file
                // was dropped under, which is the name the import sheet and the new layers show.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let copy = folder
                    .appendingPathComponent(name.isEmpty ? "Dropped" : name)
                    .appendingPathExtension(suffix)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch { continuation.resume(returning: nil) }
            }
        }
    }

    /// The name an item suggests for itself, as a file name: without an image file's extension, and with no slashes or
    /// colons. Nil when nothing is left.
    private static func baseName(_ suggested: String) -> String? {
        var name = suggested
        if UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true {
            name = (name as NSString).deletingPathExtension
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
