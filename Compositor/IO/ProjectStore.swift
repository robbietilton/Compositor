import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    nonisolated static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    nonisolated static let photoshopLargeImage = UTType(importedAs: "com.adobe.photoshop-large-image")
    static let importableImages: [UTType] = [.jpeg, .png, .heic, .tiff, .photoshopImage, .photoshopLargeImage, .rawImage, .svg]
}

nonisolated struct ProjectManifest: Codable, Sendable {
    /// The format version new saves write.
    static let current = 9
    /// Every version `load` accepts. The package-header check, the manifest check and the error
    /// message all read this, so they cannot drift apart when `current` is bumped.
    static let supported = 1...ProjectManifest.current

    var format = "com.compositor.project"
    var version = ProjectManifest.current
    var colorSpace = "sRGB"
    var resolution: Double? = nil // Older version-1 projects default to 72 pixels/inch.
    let documentID: UUID
    let width: Int
    let height: Int
    let activeLayerID: UUID?
    var layers: [ProjectLayerRecord]
    /// Alignment guides. Missing on versions 1–7.
    var guides: [CanvasGuide]? = nil
}

nonisolated struct ProjectLayerRecord: Codable, Sendable {
    let id: UUID
    let name: String
    var isVisible: Bool
    let transform: LayerTransform
    let imageFile: String?
    var parentID: UUID? = nil
    var isGroup: Bool? = nil
    var opacity: Double? = nil
    var blendMode: LayerBlendMode? = nil
    var maskFile: String? = nil
    var maskEnabled: Bool? = nil
    var maskSourceID: UUID? = nil
    var adjustment: LayerAdjustment? = nil
    /// A mask moved apart from its layer: where it sits on the document.
    var maskPlacement: LayerTransform? = nil
    /// Nil (older projects) is linked.
    var maskLinked: Bool? = nil
    /// A shape layer's shape, drawn again when the layer is scaled. Older versions ignore it and keep the pixels.
    var shape: LayerShapeStyle? = nil
    /// The stroke and drop shadow drawn around the layer.
    var effects: LayerEffects? = nil
    var text: LayerTextStyle? = nil
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
}

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: localized("This is not a valid Compositor project, or its metadata is damaged.")
        case .version(let version): String(localized: "This project uses format version \(version). This app supports versions \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound).")
        case .missingImage: localized("An image inside the project is missing or damaged. The current document has not been replaced.")
        case .tooLarge: String(localized: "This project exceeds the supported canvas, layer, file-size, or \(DocumentLimits.documentBudgetMegapixels)-megapixel document limit.")
        case .encode: localized("An image could not be saved. The previous project has not been replaced.")
        }
    }
}

actor ProjectStore {
    static let shared = ProjectStore()
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    func save(_ snapshot: ProjectSnapshot, to url: URL) throws {
        try validate(snapshot.manifest)
        var images: [String: FileWrapper] = [:]
        var pixels = 0, maskPixels = 0
        for layer in snapshot.manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            guard let asset = (isMask ? snapshot.masks : snapshot.images)[layer.id] else { throw ProjectError.missingImage }
            if isMask {
                guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels)
            } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
            let data = try autoreleasepool {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                    throw ProjectError.encode
                }
                CGImageDestinationAddImage(destination, asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                return data as Data
            }
            images[filename] = FileWrapper(regularFileWithContents: data)
          }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(snapshot.manifest)
        guard metadata.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
        let package = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ])
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                // Foundation stages a sibling package and atomically replaces the
                // destination only once the complete package has been written.
                try package.write(to: destination, options: .atomic, originalContentsURL: nil)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }

    func load(from url: URL) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try readPackage(source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid }
        return try result.get()
    }

    private func readPackage(_ url: URL) throws -> ProjectSnapshot {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ProjectError.invalid }
        let metadataURL = url.appendingPathComponent("manifest.json")
        try checkFile(metadataURL, inside: url, maximumBytes: 4 * 1024 * 1024)
        let manifest: ProjectManifest
        let metadata = try Data(contentsOf: metadataURL)
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: metadata) }
        catch { throw ProjectError.invalid }
        guard header.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(header.version) else { throw ProjectError.version(header.version) }
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: metadata) }
        catch { throw ProjectError.invalid }
        try validate(manifest)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0
        for layer in manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(filename)
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
            let asset = try autoreleasepool {
                // Decoded from the file's bytes in memory, not from the file: an image made from a file source stays tied
                // to it, and the next save replaces that file (ImageIO: "mmapped file changed"), so an image kept for undo
                // could later read someone else's pixels.
                let bytes = try Data(contentsOf: file)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
                if isMask { try checkSize(width: width, height: height, used: &maskPixels) }
                else { try checkSize(width: width, height: height, used: &pixels) }
                guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 96,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw ProjectError.missingImage }
                if isMask, !LayerMask.isValid(image) { throw ProjectError.invalid }
                return ImportedImage(image: image, thumbnail: thumbnail, name: layer.name)
            }
            if isMask { masks[layer.id] = asset } else { images[layer.id] = asset }
          }
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }

    private func validate(_ manifest: ProjectManifest) throws {
        guard manifest.format == "com.compositor.project" else { throw ProjectError.invalid }
        guard ProjectManifest.supported.contains(manifest.version) else { throw ProjectError.version(manifest.version) }
        guard manifest.colorSpace == "sRGB" else { throw ProjectError.invalid }
        if let resolution = manifest.resolution {
            guard resolution.isFinite, (1...9600).contains(resolution) else { throw ProjectError.invalid }
        }
        guard (1...DocumentLimits.maxSide).contains(manifest.width), (1...DocumentLimits.maxSide).contains(manifest.height),
              manifest.layers.count <= 10_000 else { throw ProjectError.tooLarge }
        for layer in manifest.layers {
            if let text = layer.text {
                guard text.isValid, layer.imageFile != nil, layer.isGroup != true, layer.adjustment == nil else { throw ProjectError.invalid }
            }
            if let adjustment = layer.adjustment {
                guard manifest.version >= 7, layer.isGroup != true, layer.imageFile == nil, adjustment.isValid else { throw ProjectError.invalid }
                if adjustment.kind == .gaussianBlur || adjustment.kind == .motionBlur || adjustment.kind == .addNoise {
                    guard manifest.version >= 9 else { throw ProjectError.invalid }
                }
            }
            // Layer masks arrived in version 4, folder masks in version 6.
            guard layer.maskFile == nil || (manifest.version >= (layer.isGroup == true ? 6 : 4)
                && layer.maskFile == "\(layer.id.uuidString).mask.png"),
                layer.maskEnabled == nil || layer.maskFile != nil,
                layer.maskPlacement.map({ $0.isValid && layer.maskFile != nil }) ?? true else { throw ProjectError.invalid }
            let opacity = layer.opacity ?? 1
            let blend = layer.blendMode ?? .normal
            // Folders took an opacity of their own in version 8, which multiplies into what is inside
            // them; their blend mode is still pass-through, so it stays Normal.
            guard opacity.isFinite, (0...1).contains(opacity),
                  (manifest.version >= 3 || (opacity == 1 && blend == .normal)),
                  (layer.isGroup != true || (blend == .normal && (manifest.version >= 8 || opacity == 1))) else { throw ProjectError.invalid }
        }
        try LayerHierarchy.validate(manifest.layers)
        try LiveMaskGraph.validate(manifest.layers)
        if manifest.version < 5, manifest.layers.contains(where: { $0.maskSourceID != nil }) { throw ProjectError.invalid }
        if manifest.version == 1, manifest.layers.contains(where: { $0.parentID != nil || $0.isGroup == true }) { throw ProjectError.invalid }
        var ids = Set<UUID>()
        for layer in manifest.layers {
            guard ids.insert(layer.id).inserted, layer.transform.isValid,
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  layer.name.utf8.count <= 16_384,
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png" else { throw ProjectError.invalid }
        }
        if let id = manifest.activeLayerID, !ids.contains(id) { throw ProjectError.invalid }
        try validateGuides(manifest)
    }

    private func validateGuides(_ manifest: ProjectManifest) throws {
        let guides = manifest.guides ?? []
        if manifest.version < 8 {
            guard guides.isEmpty else { throw ProjectError.invalid }
            return
        }
        guard guides.count <= 1_000 else { throw ProjectError.tooLarge }
        var ids = Set<UUID>()
        for guide in guides {
            guard ids.insert(guide.id).inserted, guide.position.isFinite, abs(guide.position) <= 1_000_000 else {
                throw ProjectError.invalid
            }
        }
    }

    private func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.documentPixelBudget - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    private func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw ProjectError.tooLarge }
    }
}
