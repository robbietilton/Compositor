import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import UniformTypeIdentifiers

extension UTType {
    static let compositorProject = UTType(exportedAs: "com.compositor.project", conformingTo: .package)
    nonisolated static let photoshopImage = UTType(importedAs: "com.adobe.photoshop-image")
    nonisolated static let photoshopLargeImage = UTType(importedAs: "com.adobe.photoshop-large-image")
    nonisolated static let importableImages: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .webP, .openEXR, .radianceHDR,
                                                         .photoshopImage, .photoshopLargeImage, .rawImage, .svg]
    /// OpenEXR, the format renders (Blender's among them) keep light brighter than white in.
    nonisolated static let openEXR = UTType("com.ilm.openexr-image") ?? .image
    /// Radiance HDR (.hdr), the usual format for HDRI panoramas.
    nonisolated static let radianceHDR = UTType("public.radiance") ?? .image
}

nonisolated struct ProjectManifest: Codable, Sendable {
    /// The format version new saves write.
    static let current = 13
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

/// The bytes of a project's images as its package last held them, read or written, so a save writes an image that
/// hasn't changed as it was rather than encoding it again. Each open project keeps one; images are kept by identity,
/// and only those the package holds. An 8-bit image read from the package costs nothing more, as its bytes are what
/// it's drawn from; a 16-bit or HDR layer's, and any a save encoded, keep their bytes beside their pixels, so when
/// memory runs short they're all let go, and the next save encodes everything.
nonisolated final class EncodedImages: @unchecked Sendable {
    /// What a layer's or mask's file holds, by identity: its image and, for a 16-bit or HDR layer, the 16-bit pixels
    /// the file is encoded from (`DeepLayer.flattened`), which an edit can replace apart from the image; and how, as
    /// a mask's file holds its image alone, and an EXR whose light all stays within white is read as a 16-bit layer,
    /// whose file is PNG (`DeepLayer.wideAsset`), so its bytes mustn't be written as that PNG.
    struct Pixels: Hashable {
        let image: ObjectIdentifier
        let deep: ObjectIdentifier?
        let mask: Bool, exr: Bool
        init(_ asset: ImportedImage, mask: Bool, exr: Bool) {
            image = ObjectIdentifier(asset.image)
            deep = asset.deep.map { ObjectIdentifier($0) }
            self.mask = mask
            self.exr = exr
        }
    }
    /// The images are held so their identifiers can't be reused by others while their bytes are kept.
    private let held = Mutex<(bytes: [Pixels: (image: CGImage, deep: CGImage?, data: Data)], encoded: Int)>(([:], 0))
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))

    init() {
        pressure.setEventHandler { [weak self] in self?.hold([]) }
        pressure.resume()
    }

    deinit { pressure.cancel() }

    /// The bytes `asset` was read from or last written as, as a `mask`'s file or a layer's, PNG or with `exr`, OpenEXR.
    func data(for asset: ImportedImage, mask: Bool, exr: Bool) -> Data? {
        held.withLock { $0.bytes[Pixels(asset, mask: mask, exr: exr)]?.data }
    }

    /// What the package holds now: these assets, as these bytes in these files' formats, `encoded` of them made just
    /// now. What it no longer holds is let go.
    func hold(_ files: [(asset: ImportedImage, mask: Bool, exr: Bool, data: Data)], encoded: Int = 0) {
        held.withLock {
            $0.bytes = Dictionary(files.map { (Pixels($0.asset, mask: $0.mask, exr: $0.exr), ($0.asset.image, $0.asset.deep, $0.data)) },
                                  uniquingKeysWith: { first, _ in first })
            $0.encoded += encoded
        }
    }

    /// How many images saves have had to encode, for tests.
    var encoded: Int { held.withLock { $0.encoded } }
}

nonisolated enum ProjectError: LocalizedError {
    case invalid, version(Int), missingImage, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Compositor project, or its metadata is damaged."
        case .version(let version): "This project uses format version \(version). This app supports versions \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound)."
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

    func save(_ snapshot: ProjectSnapshot, to url: URL, quickLook: QuickLookImages? = nil, encoded: EncodedImages? = nil) throws {
        let package = try Self.package(for: snapshot, quickLook: quickLook, encoded: encoded)
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

    /// The package `save` writes: the manifest, every layer's and mask's pixels as PNG (an HDR layer's as OpenEXR), and
    /// the Quick Look preview, validated as `load` validates. A caller that coordinates the write itself, as a UIDocument
    /// does, writes this. With `encoded`, an image the package already holds is written as the bytes it holds, and only
    /// the others are encoded, a few at once.
    nonisolated static func package(for snapshot: ProjectSnapshot, quickLook: QuickLookImages? = nil,
                                    encoded: EncodedImages? = nil) throws -> FileWrapper {
        let encoding = Timing.begin("Encode project")
        try validate(snapshot.manifest)
        var files: [(name: String, asset: ImportedImage, isMask: Bool)] = []
        var pixels = 0, maskPixels = 0
        for layer in snapshot.manifest.layers {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            guard let asset = (isMask ? snapshot.masks : snapshot.images)[layer.id] else { throw ProjectError.missingImage }
            if isMask {
                guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
                try checkSize(width: asset.image.width, height: asset.image.height, used: &maskPixels)
            } else { try checkSize(width: asset.image.width, height: asset.image.height, used: &pixels) }
            files.append((filename, asset, isMask))
          }
        }
        let (bytes, made) = try Self.data(for: files, reusing: encoded)
        var images: [String: FileWrapper] = [:]
        for (file, data) in zip(files, bytes) { images[file.name] = FileWrapper(regularFileWithContents: data) }
        encoded?.hold(zip(files, bytes).map { ($0.asset, $0.isMask, $0.name.hasSuffix(".exr"), $1) }, encoded: made)
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
        Timing.end(encoding, snapshot.timingDetail + (encoded == nil ? "" : ", \(made) encoded"))
        return FileWrapper(directoryWithFileWrappers: contents)
    }

    /// `files` as the bytes the package holds: each one `encoded` holds as the bytes it holds, the others encoded four
    /// at a time (a 16-bit or HDR layer's one at a time, `deepSlot`), pixels used twice once. Returns how many were
    /// encoded; throws the first file's error, in order.
    private nonisolated static func data(for files: [(name: String, asset: ImportedImage, isMask: Bool)],
                                         reusing encoded: EncodedImages?) throws -> (data: [Data], made: Int) {
        var data = files.map { encoded?.data(for: $0.asset, mask: $0.isMask, exr: $0.name.hasSuffix(".exr")) }
        // Each file to encode, once, however many files hold its pixels in its format (an HDR layer's, EXR).
        func key(_ index: Int) -> EncodedImages.Pixels {
            EncodedImages.Pixels(files[index].asset, mask: files[index].isMask, exr: files[index].name.hasSuffix(".exr"))
        }
        var missing: [Int] = [], first: [EncodedImages.Pixels: Int] = [:]
        for index in files.indices where data[index] == nil {
            if first[key(index)] == nil {
                first[key(index)] = index
                missing.append(index)
            }
        }
        let results = Mutex([Result<Data, any Error>?](repeating: nil, count: missing.count))
        let next = Atomic(0)
        DispatchQueue.concurrentPerform(iterations: min(4, missing.count)) { _ in
            while true {
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < missing.count else { return }
                let file = files[missing[index]]
                let result = Result { try autoreleasepool {
                    try oneAtATime(if: !file.isMask && file.asset.deep != nil) {
                        try encode(file.asset, mask: file.isMask, exr: file.name.hasSuffix(".exr"))
                    }
                } }
                results.withLock { $0[index] = result }
            }
        }
        for (index, result) in zip(missing, results.withLock { $0 }) { data[index] = try result!.get() }
        for index in files.indices where data[index] == nil { data[index] = data[first[key(index)]!] }
        return (data.map { $0! }, missing.count)
    }

    /// `asset`'s file: its pixels as PNG, or with `exr`, as OpenEXR, which keeps an HDR layer's light brighter than
    /// white (`ImportedImage.file(for:)`). A `mask` is its 8-bit image, which is all a mask's file holds.
    private nonisolated static func encode(_ asset: ImportedImage, mask: Bool, exr: Bool) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (exr ? UTType.openEXR : .png).identifier as CFString, 1, nil) else {
            throw ProjectError.encode
        }
        // A 16-bit or HDR layer saves its full pixels; `image` is only their dithered copy.
        CGImageDestinationAddImage(destination, mask ? asset.image : try DeepLayer.flattened(asset) ?? asset.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
        return data as Data
    }

    /// One 16-bit or HDR layer's file decoded or encoded at a time, whatever reads and saves are going on: either draws
    /// the whole layer into its own pixels (`DeepLayer`), some 12 bytes a pixel kept and 8 to 16 more in passing, and
    /// four big ones at once in the lanes could be all a 3 GB iPad lets an app have. 8-bit files keep their four lanes.
    private nonisolated static let deepSlot = DispatchSemaphore(value: 1)

    /// `work`, in the deep slot when `deep` (one at a time with every other deep file's), otherwise now.
    private nonisolated static func oneAtATime<Made>(if deep: Bool = true, _ work: () throws -> Made) rethrows -> Made {
        guard deep else { return try work() }
        deepSlot.wait()
        defer { deepSlot.signal() }
        return try work()
    }

    func load(from url: URL, encoded: EncodedImages? = nil) throws -> ProjectSnapshot {
        var coordinationError: NSError?
        var result: Result<ProjectSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try Self.readPackage(source, encoded: encoded) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProjectError.invalid }
        return try result.get()
    }

    /// How far `readPackage` has come, said on the thread doing the work for whoever shows it. The thumbnails' counts
    /// come from a few lanes at once, and can arrive out of order.
    nonisolated enum ReadProgress: Sendable, Equatable {
        /// The manifest is read and checked: the canvas's size, its layers, and how many image and mask files they have.
        case manifest(width: Int, height: Int, layers: Int, files: Int)
        /// The first `done` layers' files are read and checked, in package order.
        case layers(done: Int)
        /// `done` files have their image and thumbnail made, or failed to.
        case thumbnails(done: Int)
    }

    /// Reads a package whose reading is already coordinated: `load` coordinates it, and so does a UIDocument. `progress`
    /// is told how far it has come as it goes, and `encoded` what bytes each image was read from.
    nonisolated static func readPackage(_ url: URL, encoded: EncodedImages? = nil,
                                        progress: (@Sendable (ReadProgress) -> Void)? = nil) throws -> ProjectSnapshot {
        let reading = Timing.begin("Read project")
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
        if let progress {
            let files = manifest.layers.reduce(0) { $0 + ($1.imageFile == nil ? 0 : 1) + ($1.maskFile == nil ? 0 : 1) }
            progress(.manifest(width: manifest.width, height: manifest.height, layers: manifest.layers.count, files: files))
        }
        // Every layer's and mask's file checked first, one by one, then read, a few at once: a package faulty in more than
        // one file is refused for the first fault the checks find, before any found reading it.
        var files: [PackedImage] = []
        var pixels = 0, maskPixels = 0
        for (index, layer) in manifest.layers.enumerated() {
          for isMask in [false, true] {
            guard let filename = isMask ? layer.maskFile : layer.imageFile else { continue }
            let file = url.appendingPathComponent("images").appendingPathComponent(filename)
            try checkFile(file, inside: url, maximumBytes: 512 * 1024 * 1024)
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
            files.append(PackedImage(layer: layer.id, name: layer.name, isMask: isMask, exr: exr, depth: depth, bytes: bytes, source: source))
          }
          progress?(.layers(done: index + 1))
        }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let assets = try assets(for: files, progress: progress)
        for (file, asset) in zip(files, assets) {
            if file.isMask { masks[file.layer] = asset } else { images[file.layer] = asset }
        }
        encoded?.hold(zip(assets, files).map { ($0, $1.isMask, $1.exr, $1.bytes) })
        let snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: masks)
        Timing.end(reading, snapshot.timingDetail)
        return snapshot
    }

    /// A layer's or mask's file in a package being read, checked and waiting for its image and thumbnail.
    private struct PackedImage: @unchecked Sendable {
        let layer: UUID
        let name: String
        let isMask: Bool
        /// An HDR layer's OpenEXR, and the file's bits a channel: 16 for a 16-bit layer's PNG. Either is read into a
        /// layer that keeps its pixels (`DeepLayer`).
        let exr: Bool, depth: Int
        /// The file's bytes, which a save writes again while the image is unchanged.
        let bytes: Data
        /// Read by one call of `asset(for:)` only.
        let source: CGImageSource
    }

    /// `files` read, a few at once: their thumbnails are most of the time a package takes to read. Throws the first
    /// file's error, in package order.
    private nonisolated static func assets(for files: [PackedImage],
                                           progress: (@Sendable (ReadProgress) -> Void)?) throws -> [ImportedImage] {
        let results = Mutex([Result<ImportedImage, any Error>?](repeating: nil, count: files.count))
        let next = Atomic(0), finished = Atomic(0)
        // Four at a time, as many as the iPad has performance cores; each takes the next file as soon as it's done.
        DispatchQueue.concurrentPerform(iterations: min(4, files.count)) { _ in
            while true {
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < files.count else { return }
                let result = Result { try autoreleasepool { try asset(for: files[index]) } }
                results.withLock { $0[index] = result }
                if let progress { progress(.thumbnails(done: finished.add(1, ordering: .relaxed).newValue)) }
            }
        }
        return try results.withLock { $0 }.map { try $0!.get() }
    }

    /// A file's image and thumbnail. The image stays as compressed as its file until something draws it, and what
    /// drawing decodes is kept where the system can let it go; a 16-bit or HDR layer's is drawn into its own pixels
    /// now, one layer at a time (`deepSlot`), and makes its own thumbnail. A mask's PNG says nothing of its color
    /// space and ImageIO takes it as Generic Gray, which saving again would write out as a profile; it's device gray,
    /// as the editor's own masks are, so saving again writes the same bytes.
    private nonisolated static func asset(for file: PackedImage) throws -> ImportedImage {
        if file.exr || file.depth == 16 {
            // The image is made in the slot too, for a format ImageIO decodes there rather than when it's drawn.
            return try oneAtATime {
                guard let image = CGImageSourceCreateImageAtIndex(file.source, 0, nil) else { throw ProjectError.missingImage }
                return try file.exr ? DeepLayer.wideAsset(image, name: file.name) : DeepLayer.asset(image, name: file.name)
            }
        }
        guard var image = CGImageSourceCreateImageAtIndex(file.source, 0, nil) else { throw ProjectError.missingImage }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(file.source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ProjectError.missingImage }
        if file.isMask {
            guard LayerMask.isValid(image) else { throw ProjectError.invalid }
            if image.colorSpace?.name == CGColorSpace.genericGrayGamma2_2, let gray = image.copy(colorSpace: CGColorSpaceCreateDeviceGray()) {
                image = gray
            }
        }
        return ImportedImage(image: image, thumbnail: thumbnail, name: file.name)
    }

    private nonisolated static func validate(_ manifest: ProjectManifest) throws {
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

    private nonisolated static func validateGuides(_ manifest: ProjectManifest) throws {
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

    private nonisolated static func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height), width * height <= DocumentLimits.documentPixelBudget - used else {
            throw ProjectError.tooLarge
        }
        used += width * height
    }

    private nonisolated static func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw ProjectError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw ProjectError.tooLarge }
    }
}
