import Compression
import CoreGraphics
import Foundation

/// Game textures pack four grayscale maps into one image's red, green, blue and alpha (metallic, ambient occlusion,
/// detail and smoothness, say). Export As › Channel Pack writes one from layers, keeping a pixel's color where its
/// alpha is 0, which an ordinary image throws away (it stores color multiplied by alpha) but a packed texture needs.
nonisolated enum ChannelPack {
    enum Channel: String, CaseIterable, Sendable {
        case red = "Red", green = "Green", blue = "Blue", alpha = "Alpha"
        /// Layer names that pick a layer for this channel without being asked.
        var names: Set<String> {
            switch self {
            case .red: ["r", "red"]
            case .green: ["g", "green"]
            case .blue: ["b", "blue"]
            case .alpha: ["a", "alpha"]
            }
        }
    }

    /// What fills a channel: a layer or group, read as grayscale, or solid black or white.
    enum Source: Hashable, Sendable {
        case black, white
        case layer(UUID)
    }

    /// A channel's source when none has been chosen: a layer named for it (R, Red, …), otherwise black, or white for
    /// alpha, so an unused alpha leaves the texture opaque.
    static func defaultSource(for channel: Channel, in layers: [ProjectLayerRecord]) -> Source {
        let named = layers.last { channel.names.contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }
        return named.map { .layer($0.id) } ?? (channel == .alpha ? .white : .black)
    }

    /// Four planes of `width` × `height` bytes as straight (not premultiplied) RGBA.
    static func interleave(_ planes: [[UInt8]], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<4 { bytes[pixel * 4 + channel] = planes[channel][pixel] }
        }
        return bytes
    }

    /// Straight RGBA bytes as an image that keeps them as they are; `opaque` ignores the alpha, for showing the color
    /// channels on screen.
    static func image(_ bytes: [UInt8], width: Int, height: Int, opaque: Bool = false) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast : .last).rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ExportError.render }
        return image
    }

    /// Straight RGBA bytes as a PNG, written here rather than by Image I/O: macOS 26's encoder lost the color under
    /// fully transparent pixels (macOS 27's kept it), and a packed texture needs it on every version. Each row is
    /// stored unfiltered and the whole compressed, as the format allows; the file is sRGB at `resolution`.
    static func png(_ bytes: [UInt8], width: Int, height: Int, resolution: Double) throws -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity((width * 4 + 1) * height)
        for row in 0..<height {
            raw.append(0) // no filter
            raw.append(contentsOf: bytes[(row * width * 4)..<((row + 1) * width * 4)])
        }
        // Compression's zlib is raw deflate: the zlib stream PNG wants adds a header and an Adler-32 checksum.
        var deflated = [UInt8](repeating: 0, count: raw.count + raw.count / 100 + 1024)
        let size = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        guard size > 0 else { throw ExportError.encode }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let stream = [0x78, 0x9C] + deflated[0..<size] + bigEndian((b << 16) | a)

        var file = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ payload: [UInt8]) {
            let body = Array(type.utf8) + payload
            file.append(contentsOf: bigEndian(UInt32(payload.count)) + body + bigEndian(crc32(body)))
        }
        // 8 bits a channel, RGBA, no interlacing.
        chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 6, 0, 0, 0])
        chunk("sRGB", [0])
        let perMeter = UInt32(max(1, (resolution / 0.0254).rounded()))
        chunk("pHYs", bigEndian(perMeter) + bigEndian(perMeter) + [1])
        chunk("IDAT", stream)
        chunk("IEND", [])
        return file
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32(0xFFFF_FFFF)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    /// An image read as grayscale at `width` × `height`: drawn over black, so transparency counts as black, and weighed
    /// by how bright each color looks.
    static func gray(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var plane = [UInt8](repeating: 0, count: width * height)
        for pixel in 0..<(width * height) {
            let r = Double(data[pixel * 4]), g = Double(data[pixel * 4 + 1]), b = Double(data[pixel * 4 + 2])
            plane[pixel] = UInt8(min(255, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
        }
        return plane
    }

    /// `snapshot` with only `id` showing: it and the groups it's in shown, the layers inside it as they are, every
    /// other layer hidden. A layer picked for a channel is used even when it's hidden in the document.
    static func isolating(_ id: UUID, in snapshot: ProjectSnapshot) -> ProjectSnapshot {
        let layers = snapshot.manifest.layers
        let parents = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0.parentID) })
        var ancestors: Set<UUID> = [id]
        var next = parents[id] ?? nil
        while let parent = next { ancestors.insert(parent); next = parents[parent] ?? nil }
        func isInside(_ layer: UUID) -> Bool {
            var next = parents[layer] ?? nil
            while let parent = next { if parent == id { return true }; next = parents[parent] ?? nil }
            return false
        }
        var manifest = snapshot.manifest
        for index in manifest.layers.indices {
            let layer = manifest.layers[index].id
            if ancestors.contains(layer) { manifest.layers[index].isVisible = true }
            else if !isInside(layer) { manifest.layers[index].isVisible = false }
        }
        return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
    }
}

extension ImageExporter {
    /// Export As › Channel Pack: each channel's source read as grayscale at `width` × `height`, packed into one PNG
    /// of straight RGBA, and its color channels to show (the alpha would hide them).
    func channelPack(_ snapshot: ProjectSnapshot, sources: [ChannelPack.Source], width: Int, height: Int)
        throws -> (data: Data, preview: CGImage) {
        guard sources.count == 4, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        var planes: [[UInt8]] = []
        var rendered: [UUID: [UInt8]] = [:]
        for source in sources {
            try Task.checkCancellation()
            switch source {
            case .black: planes.append([UInt8](repeating: 0, count: width * height))
            case .white: planes.append([UInt8](repeating: 255, count: width * height))
            case .layer(let id):
                if let plane = rendered[id] { planes.append(plane); continue }
                let raster = try render(ChannelPack.isolating(id, in: snapshot))
                let plane = try ChannelPack.gray(raster.image, width: width, height: height)
                rendered[id] = plane
                planes.append(plane)
            }
        }
        let bytes = ChannelPack.interleave(planes, width: width, height: height)
        let resolution = snapshot.manifest.resolution ?? 72
        return (try ChannelPack.png(bytes, width: width, height: height, resolution: resolution),
                try ChannelPack.image(bytes, width: width, height: height, opaque: true))
    }
}
