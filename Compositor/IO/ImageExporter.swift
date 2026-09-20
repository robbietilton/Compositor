import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

nonisolated enum ExportError: LocalizedError {
    case tooLarge, render, encode
    var errorDescription: String? {
        switch self {
        case .tooLarge: "Image export supports canvases up to 100 megapixels and 30,000 pixels per side."
        case .render: "The canvas could not be rendered. Try a smaller canvas."
        case .encode: "The image could not be encoded."
        }
    }
}

actor ImageExporter {
    static let shared = ImageExporter()

    func render(_ snapshot: ProjectSnapshot) throws -> ExportRaster {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...30_000).contains(width), (1...30_000).contains(height),
              width * height <= 100_000_000 else { throw ExportError.tooLarge }
        return try autoreleasepool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ExportError.render
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
            for layer in snapshot.manifest.layers {
                guard layer.imageFile == nil || snapshot.images[layer.id] != nil,
                      layer.maskFile == nil || snapshot.masks[layer.id] != nil else { throw ProjectError.missingImage }
            }
            try LiveMaskGraph.validate(snapshot.manifest.layers)
            let live = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height), source: { records[$0]?.maskSourceID }) { id, target in
                guard let layer = records[id], let image = snapshot.images[id]?.image else { return }
                let opacity = layer.effectiveOpacity(in: records)
                let mask = snapshot.mask(for: layer).flatMap { $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height) }
                let effects = LayerEffectsRenderer.cached(image, mask: mask, effects: layer.effects)
                func drawLayer(_ mode: LayerBlendMode, _ into: CGContext) {
                    if let effects {
                        let grown = LayerEffectsRenderer.placed(layer.transform, image: effects.image, inset: effects.inset)
                        LayerRenderer.draw(effects.image, transform: grown, center: grown.center,
                            opacity: opacity, blendMode: mode, mask: nil, in: into)
                        return
                    }
                    LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                        opacity: opacity, blendMode: mode, mask: mask, in: into)
                }
                let mode = layer.blendMode ?? .normal
                // Core Graphics blends these two wrong; see SeparableBlend.
                if SeparableBlend.isCoreGraphicsWrong(mode), SeparableBlend.draw(mode, in: target, body: { drawLayer(.normal, $0) }) { return }
                drawLayer(mode, target)
            }
            live.adjustment = { records[$0]?.adjustment }
            live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
            live.adjustmentClip = { id, ctx in
                if let layer = records[id], let image = snapshot.mask(for: layer)?.enabledImage {
                    FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
                }
            }
            live.prepareStacks(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, blend: { records[$0]?.blendMode ?? .normal })
            FolderMaskClip.draw(LayerHierarchy.visibleLayers(snapshot.manifest.layers).map(\.id), parent: { records[$0]?.parentID }, clip: { id in
                guard let folder = records[id], let image = snapshot.mask(for: folder)?.enabledImage else { return nil }
                let clip = FolderMaskClip(image: image, transform: folder.transform)
                return { clip.apply(center: folder.transform.center, in: $0) }
            }, in: context) { live.drawComposite($0, in: context) }
            guard let image = context.makeImage() else { throw ExportError.render }
            return ExportRaster(image: image, resolution: snapshot.manifest.resolution ?? 72)
        }
    }

    func pngData(_ snapshot: ProjectSnapshot) throws -> Data {
        let raster = try render(snapshot)
        return try encode(raster.image, type: .png, properties: [
            kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution
        ] as CFDictionary)
    }

    /// A flattened single-layer PSD (8BPS RGBA); layers are not preserved. ImageIO's PSD writer
    /// stores the composite's channels as premultiplied bytes no matter what alpha flavor it is
    /// handed (verified on this SDK: premultipliedLast and straight inputs produce byte-identical
    /// files), while the PSD format — Photoshop included — reads the composite as straight alpha,
    /// so translucent colors would come out darkened by their own alpha. The composite section is
    /// therefore rewritten here with unpremultiplied channels.
    func psdData(_ snapshot: ProjectSnapshot) throws -> Data {
        guard let psd = UTType.psd else { throw ExportError.encode }
        let raster = try render(snapshot)
        let encoded = try encode(raster.image, type: psd, properties: [
            kCGImagePropertyDPIWidth: raster.resolution, kCGImagePropertyDPIHeight: raster.resolution
        ] as CFDictionary)
        let width = raster.image.width, height = raster.image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ExportError.encode
        }
        context.draw(raster.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { throw ExportError.encode }
        // `straightened` unpremultiplies the pixels itself; keep exactly one unpremultiply on the path.
        return try autoreleasepool {
            try PSDCompositeStraightener.straightened(encoded, rgba: pixels, width: width, height: height)
        }
    }

    private func encode(_ image: CGImage, type: UTType, properties: CFDictionary? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ExportError.encode
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        return data as Data
    }

    func jpeg(_ raster: ExportRaster, options: JPEGOptions) throws -> JPEGResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = raster.image
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.render }
            context.setFillColor(CGColor(colorSpace: context.colorSpace!,
                components: [options.red, options.green, options.blue, 1])!)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else { throw ExportError.render }
            try Task.checkCancellation()
            let data = try encode(flattened, type: .jpeg,
                properties: [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.quality)),
                             kCGImagePropertyDPIWidth: raster.resolution,
                             kCGImagePropertyDPIHeight: raster.resolution] as CFDictionary)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1000,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return JPEGResult(data: data, preview: preview)
        }
    }

    func exportPNG(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let data = try pngData(snapshot)
        try write(data, to: url)
    }

    func exportPSD(_ snapshot: ProjectSnapshot, to url: URL) throws {
        let data = try psdData(snapshot)
        try write(data, to: url)
    }

    func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

nonisolated struct ExportRaster: @unchecked Sendable {
    let image: CGImage
    var resolution: Double = 72
}

/// Rewrites the composite image-data section of a flattened PSD that ImageIO just wrote, replacing
/// its premultiplied channels with straight-alpha ones. Only the trailing composite section is
/// touched; the header, color-mode data, image resources and (empty) layer section stay as ImageIO
/// produced them.
private nonisolated enum PSDCompositeStraightener {
    /// - Parameters:
    ///   - psd: a PSD produced by ImageIO from the same pixels `rgba` holds.
    ///   - rgba: premultiplied RGBA8 pixels in byte order R,G,B,A (straightened here in place).
    static func straightened(_ psd: Data, rgba: UnsafeMutableRawPointer, width: Int, height: Int) throws -> Data {
        var data = psd
        // Header is 26 bytes; three length-prefixed sections (color mode, resources, layers) follow.
        var offset = 26
        for _ in 0..<3 {
            guard data.count >= offset + 4, let length = data.readBE32(at: offset) else { throw ExportError.encode }
            offset += 4 + Int(length)
        }
        guard data.count >= offset + 2 else { throw ExportError.encode }
        var vBuffer = vImage_Buffer(data: rgba, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width * 4)
        vImageUnpremultiplyData_RGBA8888(&vBuffer, &vBuffer, vImage_Flags(kvImageNoFlags))
        data.replaceSubrange(offset..., with: compositeSection(rgba: rgba, width: width, height: height))
        return data
    }

    /// The composite section (compression + per-channel PackBits rows), channels in R,G,B,A order.
    private static func compositeSection(rgba: UnsafeRawPointer, width: Int, height: Int) -> Data {
        var rows = [ArraySlice<UInt8>]()
        rows.reserveCapacity(4 * height)
        for channel in 0..<4 {
            for y in 0..<height {
                var line = [UInt8](); line.reserveCapacity(width)
                let row = UnsafeRawPointer(rgba) + y * width * 4
                for x in 0..<width { line.append(row.load(fromByteOffset: x * 4 + channel, as: UInt8.self)) }
                rows.append(packBits(line)[...])
            }
        }
        var section = Data([0, 1]) // compression = 1, RLE
        for row in rows { section.append(contentsOf: UInt16(row.count).bigEndianBytes) }
        for row in rows { section.append(contentsOf: row) }
        return section
    }

    /// Standard PackBits encoding of one scanline.
    private static func packBits(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count + input.count / 64)
        var index = 0
        while index < input.count {
            var run = 1
            while index + run < input.count && input[index + run] == input[index] && run < 128 { run += 1 }
            if run >= 3 {
                out.append(UInt8(257 - run))
                out.append(input[index])
                index += run
            } else {
                let literalStart = index
                var literalCount = 0
                while index < input.count {
                    var next = 1
                    while index + next < input.count && input[index + next] == input[index] && next < 128 { next += 1 }
                    if next >= 3 { break } // a worthwhile run starts here; keep it for a repeat packet
                    // A literal packet carries at most 128 bytes; `next` can be 2, so cap before adding,
                    // or the header degenerates into the no-op control byte 128 and shifts the whole row.
                    if literalCount + next > 128 { break }
                    index += next
                    literalCount += next
                }
                out.append(UInt8(literalCount - 1))
                out.append(contentsOf: input[literalStart..<literalStart + literalCount])
            }
        }
        return out
    }
}

private extension Data {
    /// A big-endian UInt32 at `offset`, when it fits.
    func readBE32(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        return UInt32(self[startIndex + offset]) << 24 | UInt32(self[startIndex + offset + 1]) << 16
            | UInt32(self[startIndex + offset + 2]) << 8 | UInt32(self[startIndex + offset + 3])
    }
}
private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(truncatingIfNeeded: self)] }
}
nonisolated struct JPEGOptions: Equatable, Sendable {
    var quality: Double = 0.85
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
}
nonisolated struct JPEGResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
}
