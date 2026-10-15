import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    nonisolated static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    nonisolated static let photoshopLargeImage = UTType(importedAs: "com.adobe.photoshop-large-image")
    static let importableImages: [UTType] = [.jpeg, .png, .gif, .heic, .heif, .tiff, .webP, .openEXR, .radianceHDR, .photoshopImage,
                                             .photoshopLargeImage, .rawImage, .svg]
    /// OpenEXR, the format renders (Blender's among them) keep light brighter than white in.
    static let openEXR = UTType("com.ilm.openexr-image") ?? .image
    /// Radiance HDR (.hdr), the usual format for HDRI panoramas.
    static let radianceHDR = UTType("public.radiance") ?? .image
}

nonisolated struct ProjectManifest: Codable, Sendable {
    /// The format version new saves write.
    static let current = 28
    /// Every version `load` accepts. The package-header check, the manifest check and the error
    /// message all read this, so they cannot drift apart when `current` is bumped.
    static let upstreamVersions = 1...14
    static let supported = Set(upstreamVersions).union([27, current])

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
    /// The embedded animation and masks scoped to individual frames. Missing before version 27.
    var gif: ProjectGIFRecord? = nil
}

nonisolated struct ProjectGIFRecord: Codable, Sendable {
    let sourceFile: String
    let selectedFrameIndex: Int
    var geometry: GIFFrameGeometry? = nil
    var frameMasks: [ProjectGIFMaskRecord] = []
    var framePixels: [ProjectGIFPixelsRecord] = []
    var deletedFrameIndices: [Int] = []
    var frameOrder: [GIFFrameReference]? = nil
    var timing: ProjectGIFTimingRecord? = nil

    init(sourceFile: String, selectedFrameIndex: Int, geometry: GIFFrameGeometry? = nil,
         frameMasks: [ProjectGIFMaskRecord] = [], framePixels: [ProjectGIFPixelsRecord] = [],
         deletedFrameIndices: [Int] = [], frameOrder: [GIFFrameReference]? = nil, timing: ProjectGIFTimingRecord? = nil) {
        self.sourceFile = sourceFile
        self.selectedFrameIndex = selectedFrameIndex
        self.geometry = geometry
        self.frameMasks = frameMasks
        self.framePixels = framePixels
        self.deletedFrameIndices = deletedFrameIndices
        self.frameOrder = frameOrder
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey { case sourceFile, selectedFrameIndex, geometry, frameMasks, framePixels, deletedFrameIndices, frameOrder, timing }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceFile = try values.decode(String.self, forKey: .sourceFile)
        selectedFrameIndex = try values.decode(Int.self, forKey: .selectedFrameIndex)
        geometry = try values.decodeIfPresent(GIFFrameGeometry.self, forKey: .geometry)
        frameMasks = try values.decodeIfPresent([ProjectGIFMaskRecord].self, forKey: .frameMasks) ?? []
        framePixels = try values.decodeIfPresent([ProjectGIFPixelsRecord].self, forKey: .framePixels) ?? []
        deletedFrameIndices = try values.decodeIfPresent([Int].self, forKey: .deletedFrameIndices) ?? []
        frameOrder = try values.decodeIfPresent([GIFFrameReference].self, forKey: .frameOrder)
        timing = try values.decodeIfPresent(ProjectGIFTimingRecord.self, forKey: .timing)
    }
}

nonisolated struct ProjectGIFTimingRecord: Codable, Sendable {
    var mode: GIFDelayMode
    var uniformDelay: TimeInterval
    var frameDelays: [ProjectGIFDelayRecord]

    init(_ timing: GIFFrameTiming) {
        mode = timing.mode
        uniformDelay = timing.uniformDelay
        frameDelays = timing.frameDelays.keys.sorted().map { ProjectGIFDelayRecord(index: $0, duration: timing.frameDelays[$0]!) }
    }

    var frameTiming: GIFFrameTiming {
        var timing = GIFFrameTiming(mode: mode, uniformDelay: uniformDelay)
        for record in frameDelays { timing.frameDelays[record.index] = record.duration }
        return timing
    }

    var isValid: Bool {
        frameDelays.count <= GIFTimelineLimits.maxFrames && frameTiming.isValid
            && Set(frameDelays.map(\.index)).count == frameDelays.count
            && frameDelays.allSatisfy { (0..<GIFTimelineLimits.frameIdentityLimit).contains($0.index) }
    }
}

nonisolated struct ProjectGIFDelayRecord: Codable, Sendable {
    let index: Int
    let duration: TimeInterval
}

nonisolated struct ProjectGIFPixelsRecord: Codable, Sendable {
    let index: Int
    let imageFile: String
}

nonisolated struct ProjectGIFMaskRecord: Codable, Sendable {
    let index: Int
    let maskFile: String
    var isEnabled = true
    var placement: LayerTransform? = nil
    var isLinked = true

    init(index: Int, maskFile: String, isEnabled: Bool = true, placement: LayerTransform? = nil, isLinked: Bool = true) {
        self.index = index
        self.maskFile = maskFile
        self.isEnabled = isEnabled
        self.placement = placement
        self.isLinked = isLinked
    }

    private enum CodingKeys: String, CodingKey { case index, maskFile, isEnabled, placement, isLinked }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        maskFile = try values.decode(String.self, forKey: .maskFile)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        placement = try values.decodeIfPresent(LayerTransform.self, forKey: .placement)
        isLinked = try values.decodeIfPresent(Bool.self, forKey: .isLinked) ?? true
    }
}

nonisolated struct ProjectSnapshot: @unchecked Sendable {
    // Snapshot dictionaries are value copies; their CGImages and GIF sources are immutable across actors.
    let manifest: ProjectManifest
    let images: [UUID: ImportedImage]
    var masks: [UUID: ImportedImage] = [:]
    var animations: [UUID: GIFAnimation] = [:]
    var frameMasks: [UUID: [Int: LayerMask]] = [:]
}

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions \(ProjectManifest.upstreamVersions.lowerBound)–\(ProjectManifest.upstreamVersions.upperBound), 27, and \(ProjectManifest.current)."
        case .missingImage: "An image inside the project is missing or damaged. The current document has not been replaced."
        case .tooLarge: "This project exceeds the supported canvas, layer, file-size, or \(DocumentLimits.documentBudgetMegapixels)-megapixel document limit."
        case .encode: "An image could not be saved. The previous project has not been replaced."
        }
    }
}

actor ProjectStore {
    static let shared = ProjectStore()
    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    func save(_ snapshot: ProjectSnapshot, to url: URL, quickLook: QuickLookImages? = nil) throws {
        try validate(snapshot.manifest)
        let animatedIDs = Set(snapshot.manifest.layers.filter { $0.gif != nil }.map(\.id))
        guard Set(snapshot.animations.keys) == animatedIDs,
              Set(snapshot.frameMasks.keys).isSubset(of: animatedIDs) else { throw ProjectError.invalid }
        var images: [String: FileWrapper] = [:]
        var pixels = 0, maskPixels = 0
        var gifBytes = 0, thumbnailPixels = 0
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
                // An HDR layer saves as OpenEXR, which keeps light brighter than white (`ImportedImage.file(for:)`).
                let type = !isMask && filename.hasSuffix(".exr") ? UTType.openEXR : .png
                guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                    throw ProjectError.encode
                }
                // A 16-bit or HDR layer saves its full pixels; `image` is only their dithered copy.
                CGImageDestinationAddImage(destination, isMask ? asset.image : try DeepLayer.flattened(asset) ?? asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                return data as Data
            }
            guard data.count <= 512 * 1024 * 1024 else { throw ProjectError.tooLarge }
            if layer.gif != nil, !isMask, asset.deep != nil { throw ProjectError.invalid }
            images[filename] = FileWrapper(regularFileWithContents: data)
          }
            guard let gif = layer.gif else { continue }
            guard let animation = snapshot.animations[layer.id], let image = snapshot.images[layer.id]?.image else {
                throw ProjectError.missingImage
            }
            try validateAnimation(animation, record: gif, image: image)
            try checkGIFBudget(animation.source, bytes: &gifBytes, thumbnails: &thumbnailPixels)
            let masks = snapshot.frameMasks[layer.id] ?? [:]
            guard Set(masks.keys) == Set(gif.frameMasks.map(\.index)) else { throw ProjectError.invalid }
            images[gif.sourceFile] = FileWrapper(regularFileWithContents: animation.source.data)
            for record in gif.framePixels {
                guard let asset = animation.framePixels[record.index] else { throw ProjectError.missingImage }
                try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels)
                images[record.imageFile] = FileWrapper(regularFileWithContents: try pngData(asset.image))
            }
            for record in gif.frameMasks {
                guard let mask = masks[record.index], LayerMask.isValid(mask.asset.image),
                      mask.isEnabled == record.isEnabled, mask.placement == record.placement,
                      mask.isLinked == record.isLinked else { throw ProjectError.invalid }
                try checkSize(width: mask.asset.image.width, height: mask.asset.image.height, used: &maskPixels)
                images[record.maskFile] = FileWrapper(regularFileWithContents: try pngData(mask.asset.image))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(snapshot.manifest)
        guard metadata.count <= 4 * 1024 * 1024 else { throw ProjectError.tooLarge }
        var contents = [
            "manifest.json": FileWrapper(regularFileWithContents: metadata),
            "images": FileWrapper(directoryWithFileWrappers: images)
        ]
        // Quick Look's Space-bar preview reads this by name; loading ignores it.
        if let quickLook {
            contents["QuickLook"] = FileWrapper(directoryWithFileWrappers: [
                "Preview.jpg": FileWrapper(regularFileWithContents: quickLook.preview),
            ])
        }
        let package = FileWrapper(directoryWithFileWrappers: contents)
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
        var animations: [UUID: GIFAnimation] = [:]
        var frameMasks: [UUID: [Int: LayerMask]] = [:]
        var pixels = 0, maskPixels = 0
        var gifBytes = 0, thumbnailPixels = 0
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
                // An HDR layer's EXR from version 13; masks are always PNG.
                let exr = !isMask && filename.hasSuffix(".exr")
                guard !exr || manifest.version >= 13,
                      let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetType(source) as String? == (exr ? UTType.openEXR : .png).identifier,
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      // 16-bit layer images from version 12; masks stay 8-bit.
                      case let depth = properties[kCGImagePropertyDepth] as? Int ?? 8,
                      exr || depth <= 8 || (depth == 16 && !isMask && manifest.version >= 12) else { throw ProjectError.missingImage }
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
                if exr { return try DeepLayer.wideAsset(image, name: layer.name) }
                if depth == 16 { return try DeepLayer.asset(image, name: layer.name) }
                return ImportedImage(image: image, thumbnail: thumbnail, name: layer.name)
            }
            if layer.gif != nil, !isMask, asset.deep != nil { throw ProjectError.invalid }
            if isMask { masks[layer.id] = asset } else { images[layer.id] = asset }
          }
            guard let gif = layer.gif else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(gif.sourceFile)
            let byteCount = try checkFile(file, inside: url, maximumBytes: GIFSource.byteLimit)
            guard byteCount <= GIFSource.totalByteLimit - gifBytes else { throw ProjectError.tooLarge }
            let source: GIFSource
            do { source = try GIFDecoder.source(Data(contentsOf: file), name: layer.name) }
            catch ImageImportError.tooLarge { throw ProjectError.tooLarge }
            catch ImageImportError.tooManyFrames { throw ProjectError.tooLarge }
            catch { throw ProjectError.missingImage }
            var animation = GIFAnimation(source: source, selectedFrameIndex: gif.selectedFrameIndex, geometry: gif.geometry)
            animation.deletedFrameIndices = Set(gif.deletedFrameIndices)
            animation.frameOrder = gif.frameOrder
            animation.timing = gif.timing?.frameTiming ?? GIFFrameTiming()
            guard let image = images[layer.id]?.image else { throw ProjectError.missingImage }
            for record in gif.framePixels {
                let pixelsFile = url.appendingPathComponent("images").appendingPathComponent(record.imageFile)
                try checkFile(pixelsFile, inside: url, maximumBytes: 512 * 1024 * 1024)
                animation.framePixels[record.index] = try readPNG(pixelsFile, name: layer.name, isMask: false, used: &pixels)
            }
            try validateAnimation(animation, record: gif, image: image)
            try checkGIFBudget(source, bytes: &gifBytes, thumbnails: &thumbnailPixels)
            animations[layer.id] = animation
            var loadedMasks: [Int: LayerMask] = [:]
            for record in gif.frameMasks {
                let maskFile = url.appendingPathComponent("images").appendingPathComponent(record.maskFile)
                try checkFile(maskFile, inside: url, maximumBytes: 512 * 1024 * 1024)
                let asset = try readPNG(maskFile, name: "Frame Mask", isMask: true, used: &maskPixels)
                loadedMasks[record.index] = LayerMask(asset: asset, isEnabled: record.isEnabled,
                                                    placement: record.placement, isLinked: record.isLinked)
            }
            if !loadedMasks.isEmpty { frameMasks[layer.id] = loadedMasks }
        }
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, animations: animations, frameMasks: frameMasks)
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
            if layer.shape?.smoothing == true {
                guard manifest.version >= 14 else { throw ProjectError.invalid }
            }
            if let gif = layer.gif {
                let identityLimit = manifest.version >= 28 ? GIFTimelineLimits.frameIdentityLimit : GIFTimelineLimits.maxFrames
                guard manifest.version >= 27, layer.imageFile != nil, layer.isGroup != true,
                      layer.adjustment == nil, layer.text == nil, layer.shape == nil,
                      gif.sourceFile == "\(layer.id.uuidString).gif",
                      (0..<identityLimit).contains(gif.selectedFrameIndex),
                      gif.geometry.map(\.isValid) ?? true,
                      gif.frameMasks.count <= GIFTimelineLimits.maxFrames else { throw ProjectError.invalid }
                var indices = Set<Int>()
                guard gif.deletedFrameIndices.isEmpty || manifest.version >= 28,
                      gif.deletedFrameIndices.count <= GIFTimelineLimits.maxFrames else { throw ProjectError.invalid }
                for index in gif.deletedFrameIndices {
                    guard (0..<GIFTimelineLimits.maxFrames).contains(index), indices.insert(index).inserted else {
                        throw ProjectError.invalid
                    }
                }
                indices.removeAll()
                if let order = gif.frameOrder {
                    guard manifest.version >= 28, !order.isEmpty, order.count <= GIFTimelineLimits.maxFrames else {
                        throw ProjectError.invalid
                    }
                    for frame in order {
                        guard (0..<identityLimit).contains(frame.index), indices.insert(frame.index).inserted,
                              (0..<GIFTimelineLimits.maxFrames).contains(frame.sourceIndex) else { throw ProjectError.invalid }
                    }
                    indices.removeAll()
                }
                if let timing = gif.timing {
                    guard manifest.version >= 28, timing.isValid else { throw ProjectError.invalid }
                }
                for mask in gif.frameMasks {
                    guard (0..<identityLimit).contains(mask.index), indices.insert(mask.index).inserted,
                          mask.maskFile == "\(layer.id.uuidString).frame-\(mask.index).mask.png",
                          mask.placement.map(\.isValid) ?? true else { throw ProjectError.invalid }
                }
                guard gif.framePixels.count <= GIFTimelineLimits.maxFrames else { throw ProjectError.invalid }
                indices.removeAll()
                for pixels in gif.framePixels {
                    guard (0..<identityLimit).contains(pixels.index), indices.insert(pixels.index).inserted,
                          pixels.imageFile == "\(layer.id.uuidString).frame-\(pixels.index).png" else { throw ProjectError.invalid }
                }
            }
            if let text = layer.text {
                // Per-letter colors arrived in version 10, per-letter faces in version 11.
                guard text.isValid,
                      text.colorRuns == nil || manifest.version >= 10,
                      text.fontRuns == nil || manifest.version >= 11,
                      layer.imageFile != nil, layer.isGroup != true, layer.adjustment == nil else { throw ProjectError.invalid }
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
                  layer.imageFile == nil || layer.imageFile == "\(layer.id.uuidString).png"
                    || (manifest.version >= 13 && layer.imageFile == "\(layer.id.uuidString).exr") else { throw ProjectError.invalid }
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

    private func validateAnimation(_ animation: GIFAnimation, record: ProjectGIFRecord, image: CGImage) throws {
        let source = animation.source
        guard animation.selectedFrameIndex == record.selectedFrameIndex, animation.geometry == record.geometry,
              animation.deletedFrameIndices == Set(record.deletedFrameIndices),
              animation.frameOrder == record.frameOrder, animation.hasValidFrameOrder,
              animation.timing == (record.timing?.frameTiming ?? GIFFrameTiming()),
              animation.timing.isValid(for: Set(animation.frameReferences.map(\.index))),
              !source.frames.isEmpty, source.frames.count <= GIFTimelineLimits.maxFrames,
              record.deletedFrameIndices.allSatisfy({ source.frames.indices.contains($0) }),
              animation.containsFrame(record.selectedFrameIndex),
              record.frameMasks.allSatisfy({ animation.containsFrame($0.index) }),
              Set(animation.framePixels.keys) == Set(record.framePixels.map(\.index)),
              animation.framePixels.allSatisfy({ index, asset in
                  animation.containsFrame(index) && asset.deep == nil && asset.image.bitsPerComponent <= 8
                      && asset.image.width == (record.geometry?.width ?? source.width)
                      && asset.image.height == (record.geometry?.height ?? source.height)
              }),
              (1...DocumentLimits.maxSide).contains(source.width), (1...DocumentLimits.maxSide).contains(source.height),
              image.width == (record.geometry?.width ?? source.width),
              image.height == (record.geometry?.height ?? source.height) else { throw ProjectError.invalid }
        guard source.data.count <= GIFSource.byteLimit else { throw ProjectError.tooLarge }
        guard let encoded = CGImageSourceCreateWithData(source.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(encoded) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(encoded) == source.frames.count else { throw ProjectError.missingImage }
        for (index, frame) in source.frames.enumerated() {
            guard frame.index == index, frame.duration.isFinite, frame.duration >= GIFTimelineLimits.minimumFrameDuration,
                  let properties = CGImageSourceCopyPropertiesAtIndex(encoded, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == source.width, height == source.height else { throw ProjectError.invalid }
            var pixels = 0
            try checkSize(width: width, height: height, used: &pixels)
            guard width * height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
        }
    }

    private func checkGIFBudget(_ source: GIFSource, bytes: inout Int, thumbnails: inout Int) throws {
        guard source.data.count <= GIFSource.totalByteLimit - bytes else { throw ProjectError.tooLarge }
        bytes += source.data.count
        for frame in source.frames {
            let width = frame.thumbnail.width, height = frame.thumbnail.height
            guard (1...GIFTimelineLimits.thumbnailSide).contains(width), (1...GIFTimelineLimits.thumbnailSide).contains(height),
                  width * height <= GIFSource.totalThumbnailPixelBudget - thumbnails else { throw ProjectError.tooLarge }
            thumbnails += width * height
        }
    }

    private func pngData(_ image: CGImage) throws -> Data {
        try autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw ProjectError.encode
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
            guard data.length <= 512 * 1024 * 1024 else { throw ProjectError.tooLarge }
            return data as Data
        }
    }

    private func readPNG(_ file: URL, name: String, isMask: Bool, used: inout Int) throws -> ImportedImage {
        try autoreleasepool {
            // The bytes own the pixels independently of the file, which an atomic save may replace while undo keeps them.
            let bytes = try Data(contentsOf: file)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
            try checkSize(width: width, height: height, used: &used)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ProjectError.missingImage }
            if isMask, !LayerMask.isValid(image) { throw ProjectError.invalid }
            return ImportedImage(image: image, thumbnail: thumbnail, name: name)
        }
    }

    @discardableResult
    private func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws -> Int {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw ProjectError.tooLarge }
        return size
    }
}
