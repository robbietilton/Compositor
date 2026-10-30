import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct GIFExportOptions: Equatable, Sendable {
    var loopsForever = true
    var keepsTransparency = true
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
}

nonisolated enum GIFExportError: LocalizedError {
    case tooLarge, invalidTimeline

    var errorDescription: String? {
        switch self {
        case .tooLarge:
            "Animation export supports up to \(GIFTimelineLimits.maxFrames.formatted()) frames, \(GIFExporter.pixelBudget / 1_000_000) megapixels across all exported frames, and 512 MiB of encoded data. Reduce the export size or frame count."
        case .invalidTimeline: "The selected animation timeline is missing or invalid."
        }
    }
}

/// Only the encoded bytes and one decoded preview cross actors; their image is immutable.
nonisolated struct GIFExportResult: @unchecked Sendable {
    let data: Data
    let preview: CGImage
    let durations: [TimeInterval]
}

actor GIFExporter {
    static let shared = GIFExporter()
    // ImageIO may retain frames while encoding. Bound the whole sequence, as well as each raster.
    nonisolated static let pixelBudget = DocumentLimits.maxSurfacePixels

    func encode(_ snapshot: ProjectSnapshot, width: Int, height: Int, options: GIFExportOptions,
                progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> GIFExportResult {
        try Task.checkCancellation()
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
              width * height <= DocumentLimits.maxSurfacePixels else { throw ExportError.tooLarge }
        let schedule = try GIFExportSchedule(snapshot, options: options)
        let count = schedule.frames.count
        guard count <= GIFTimelineLimits.maxFrames, width * height <= Self.pixelBudget / count else {
            throw GIFExportError.tooLarge
        }
        let durations = schedule.durations
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else {
            throw ExportError.encode
        }
        var properties: [CFString: Any] = [kCGImagePropertyGIFHasGlobalColorMap: false]
        if count > 1, options.loopsForever { properties[kCGImagePropertyGIFLoopCount] = 0 }
        // Per-frame palettes keep full-canvas transparent frames independent. ImageIO's global-palette
        // optimization can place a tiny empty delta outside a very small canvas.
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: properties] as CFDictionary)
        var images = snapshot.images, animations = snapshot.animations
        var framePositions = Array(repeating: -1, count: schedule.tracks.count)
        for position in 0..<count {
            try Task.checkCancellation()
            await progress(position, count)
            try Task.checkCancellation()
            for index in schedule.tracks.indices {
                let track = schedule.tracks[index]
                var framePosition = max(0, framePositions[index])
                while framePosition + 1 < track.starts.count,
                      track.starts[framePosition + 1] <= schedule.frames[position].sample { framePosition += 1 }
                guard framePositions[index] != framePosition else { continue }
                try Task.checkCancellation()
                let frame = track.frames[framePosition]
                images[track.layer.id] = try GIFDecoder.frame(track.animation, index: frame.index, name: track.layer.name)
                var animation = track.animation
                animation.selectedFrameIndex = frame.index
                animations[track.layer.id] = animation
                framePositions[index] = framePosition
            }
            let captured = ProjectSnapshot(manifest: snapshot.manifest, images: images, masks: snapshot.masks,
                                           animations: animations)
            let raster = try await ImageExporter.shared.render(captured)
            let sized = try await ImageExporter.shared.resized(raster, width: width, height: height)
            let image: CGImage
            if options.keepsTransparency { image = try binaryAlpha(sized.image) }
            else {
                image = try await ImageExporter.shared.flattened(sized, over: CGColor(srgbRed: options.red,
                    green: options.green, blue: options.blue, alpha: 1))
            }
            try Task.checkCancellation()
            autoreleasepool {
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: durations[position],
                    kCGImagePropertyGIFUnclampedDelayTime: durations[position]
                ]] as CFDictionary)
            }
            guard data.length <= GIFSource.byteLimit else { throw GIFExportError.tooLarge }
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }
        let bytes = data as Data
        guard bytes.count <= GIFSource.byteLimit else { throw GIFExportError.tooLarge }
        try Task.checkCancellation()
        let preview = try preview(bytes, index: 0)
        await progress(count, count)
        return GIFExportResult(data: bytes, preview: preview, durations: durations)
    }

    /// Decode the actual encoded colors for the dialog, bounded independently of export dimensions.
    func preview(_ data: Data, index: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  index >= 0, index < CGImageSourceGetCount(source),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1120,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw ExportError.encode }
            return image
        }
    }

    /// GIF has one transparent palette entry. Threshold coverage at 50%, preserving the unassociated color
    /// of retained pixels instead of darkening soft mask edges against black.
    private func binaryAlpha(_ image: CGImage) throws -> CGImage {
        try autoreleasepool {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for y in 0..<image.height {
                try Task.checkCancellation()
                for x in 0..<image.width {
                    let offset = y * context.bytesPerRow + x * 4
                    let alpha = Int(bytes[offset + 3])
                    if alpha < 128 {
                        bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = 0
                    } else if alpha < 255 {
                        for channel in 0..<3 { bytes[offset + channel] = UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha)) }
                        bytes[offset + 3] = 255
                    }
                }
            }
            guard let result = context.makeImage() else { throw ExportError.render }
            return result
        }
    }
}

extension ProjectSnapshot {
    /// Timelines offered for export, excluding layers inside hidden folders.
    nonisolated var gifExportLayers: [ProjectLayerRecord] {
        LayerHierarchy.visibleLayers(manifest.layers).filter { animations[$0.id] != nil }
    }
}
