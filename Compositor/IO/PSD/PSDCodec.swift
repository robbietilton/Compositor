import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Prefer the system `.psd` type so Open/Save match files on disk. `importedAs` can
    /// produce a parallel type that NSOpenPanel will not enable.
    static let photoshopDocument = UTType(filenameExtension: "psd")
        ?? UTType("com.adobe.photoshop-image")
        ?? UTType(importedAs: "com.adobe.photoshop-image")

    static var projectDocumentTypes: [UTType] {
        let photoshop = UTType.types(tag: "psd", tagClass: .filenameExtension, conformingTo: nil)
        return [.compositorProject] + (photoshop.isEmpty ? [photoshopDocument] : photoshop)
    }

    /// Open must include `public.image`: on-disk Photoshop files conform to it, and listing only
    /// a custom Adobe identifier leaves them greyed out next to `.comp` packages.
    static var projectOpenTypes: [UTType] {
        var types: [UTType] = [.compositorProject, .image, .data]
        types.append(contentsOf: projectDocumentTypes)
        return types
    }
}

extension URL {
    var isCompositorProject: Bool { hasProjectFilename("comp") && !hasPhotoshopFilename && !hasPhotoshopSignature }
    var isPhotoshopDocument: Bool { hasPhotoshopFilename || hasPhotoshopSignature || hasPhotoshopContentType }
    var isProjectDocument: Bool { hasProjectFilename("comp") || isPhotoshopDocument }

    var projectExtension: String {
        if hasPhotoshopFilename { return "psd" }
        if hasProjectFilename("comp") { return "comp" }
        return pathExtension.lowercased()
    }

    var hasPhotoshopFilename: Bool { hasProjectFilename("psd") }

    func hasProjectFilename(_ ext: String) -> Bool {
        filenameTokens.contains { $0 == ext || $0.hasSuffix(".\(ext)") }
    }

    /// Names only — safe for Open panel `shouldEnable` (no file I/O).
    private var filenameTokens: [String] {
        var tokens = [pathExtension, lastPathComponent, path]
        if let name = (try? resourceValues(forKeys: [.nameKey]))?.name { tokens.append(name) }
        return tokens.map { $0.lowercased() }
    }

    private var hasPhotoshopContentType: Bool {
        guard let type = (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.identifier == "com.adobe.photoshop-image" || type.conforms(to: .photoshopDocument)
    }

    var hasPhotoshopSignature: Bool {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return false }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: 4)) ?? Data()) == Data("8BPS".utf8)
    }
}

actor PSDCodec {
    static let shared = PSDCodec()

    func load(from url: URL) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 512 * 1024 * 1024 else {
                    throw PSDError.tooLarge
                }
                return try PSDReader.parse(try Data(contentsOf: source))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PSDError.invalid }
        return try result.get()
    }

    func save(_ snapshot: ProjectSnapshot, to url: URL) async throws {
        let raster = try await ImageExporter.shared.render(snapshot)
        let data = try PSDWriter.encode(snapshot, composite: raster.image)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do { try data.write(to: destination, options: .atomic) }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}
