import Foundation
import CoreGraphics

nonisolated enum CameraRawOperationRenderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        AppLocalization.string("The Camera Raw operation is unavailable or unsupported. Its source pixels have been preserved, but the adjusted image cannot be rendered.")
    }
}

/// Host-owned rendering, independent of the optional Camera Raw editing panel. Only derived pixels are cached;
/// the layer's original asset and the operation stay separate for saving, undo and later editing.
nonisolated final class CameraRawOperationRenderer: @unchecked Sendable {
    static let shared = CameraRawOperationRenderer()

    private struct Entry {
        let source: ImportedImage
        let operation: CameraRawOperation
        let rendered: ImportedImage

        func matches(_ asset: ImportedImage, _ operation: CameraRawOperation) -> Bool {
            source.image === asset.image && source.deep === asset.deep && source.raster === asset.raster
                && source.name == asset.name && self.operation == operation
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity = 4

    func render(_ asset: ImportedImage, operation: CameraRawOperation) throws -> ImportedImage {
        if let cached = lock.withLock({
            guard let index = entries.firstIndex(where: { $0.matches(asset, operation) }) else { return nil as ImportedImage? }
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.rendered
        }) { return cached }
        guard let settings = operation.settings else { throw CameraRawOperationRenderError.unavailable }
        // Preserve even the sparse raster and high-depth backing when no pixels need changing.
        guard !settings.isIdentity else { return asset }

        // Export and operation preparation call this from workers. Never hold the cache lock while doing pixel work.
        let rendered = try autoreleasepool {
            func apply(_ image: CGImage) throws -> CGImage {
                try settings.apply(image, seed: operation.seed, usesGPU: false)
            }
            if let deep = try DeepLayer.flattened(asset) {
                return try DeepLayer.asset(DeepLayer.run(deep, mixesChannels: true, through: apply), name: asset.name)
            }
            let image = try apply(asset.image)
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: asset.name)
        }
        return lock.withLock {
            // Concurrent requests may finish together. Reuse the first result so image-identity caches stay stable.
            if let known = entries.first(where: { $0.matches(asset, operation) }) { return known.rendered }
            entries.insert(Entry(source: asset, operation: operation, rendered: rendered), at: 0)
            if entries.count > capacity { entries.removeLast(entries.count - capacity) }
            return rendered
        }
    }
}

extension ImageLayer {
    /// Display-only fallback. Export must use the throwing renderer instead of presenting unadjusted pixels as final.
    var effectiveRenderAsset: ImportedImage? {
        guard let asset, let cameraRawOperation else { return asset }
        return (try? CameraRawOperationRenderer.shared.render(asset, operation: cameraRawOperation)) ?? asset
    }
}

extension CanvasDocument {
    /// A derived copy for consumers that commit the composite (merge, clipboard and flattening). Unknown operations
    /// fail before a nonthrowing drawing closure can accidentally bake their source fallback into the result.
    func renderedCameraRawOperations() throws -> CanvasDocument {
        var rendered = self
        for index in rendered.layers.indices {
            guard let operation = rendered.layers[index].cameraRawOperation else { continue }
            guard let asset = rendered.layers[index].asset else { throw CameraRawOperationRenderError.unavailable }
            rendered.layers[index].asset = try CameraRawOperationRenderer.shared.render(asset, operation: operation)
            rendered.layers[index].cameraRawOperation = nil
        }
        return rendered
    }
}
