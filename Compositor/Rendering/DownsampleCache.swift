import Accelerate
import CoreGraphics
import Foundation

/// Sharp reductions of layer images. Core Graphics resamples in one step with a filter that only looks at a
/// few neighbouring pixels, so shrinking an image 4× or 8× comes out soft or grainy at any interpolation
/// quality. This keeps a chain of halved copies made with Lanczos resampling (vImage), so a draw only ever
/// leaves Core Graphics the last reduction of at most 2×. Copies are keyed by image identity — painting makes
/// a new image — and the least recently used are dropped beyond a pixel budget.
///
/// Every halving is exactly 2×, so level `k` pixel `i` always covers source pixels `i·2^k ..< (i+1)·2^k`: a
/// piece of an image reduced on its own lines up with the whole image reduced (see `TiledLayerRenderer`).
nonisolated final class DownsampleCache: @unchecked Sendable {
    static let shared = DownsampleCache()
    /// Pixels of halved copies kept at once (about 400 MB of RGBA).
    static let pixelBudget = DocumentLimits.maxSurfacePixels
    /// Most halvings ever used; past this Core Graphics does the rest.
    static let maxLevel = 6

    private struct Entry {
        let source: CGImage
        var levels: [CGImage]
        var lastUse: UInt64
        var pixels: Int { levels.reduce(0) { $0 + $1.width * $1.height } }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clock: UInt64 = 0
    private let lock = NSLock()

    /// Halvings to draw from when an image lands `factor` output pixels per image pixel: the most that still
    /// leave the copy at least that large (0 from half size up).
    static func level(for factor: CGFloat) -> Int {
        guard factor.isFinite, factor > 0, factor < 0.5 else { return 0 }
        return min(maxLevel, Int(floor(log2(1 / Double(factor)))))
    }

    /// What to draw when `image` lands `factor` output pixels per image pixel.
    func image(_ image: CGImage, drawnAt factor: CGFloat) -> CGImage {
        self.image(image, level: Self.level(for: factor)).image
    }

    /// `image` reduced by `level` halvings, and how many were applied (fewer only if one failed). Each
    /// halving rounds up, so the copy reaches up to 2^level − 1 source pixels past the right and bottom.
    func image(_ image: CGImage, level wanted: Int) -> (image: CGImage, level: Int) {
        guard wanted >= 1, image.width > 1 || image.height > 1 else { return (image, 0) }
        let key = ObjectIdentifier(image)
        lock.lock()
        clock += 1
        var levels = entries[key].flatMap { $0.source === image ? $0.levels : nil } ?? []
        lock.unlock()
        while levels.count < wanted {
            let previous = levels.last ?? image
            guard previous.width > 1 || previous.height > 1, let next = Self.halve(previous) else { break }
            levels.append(next)
        }
        guard !levels.isEmpty else { return (image, 0) }
        lock.lock()
        if let stored = entries[key], stored.source === image, stored.levels.count >= levels.count {
            entries[key]?.lastUse = clock
        } else {
            entries[key] = Entry(source: image, levels: levels, lastUse: clock)
        }
        evict(keeping: key)
        lock.unlock()
        let applied = min(wanted, levels.count)
        return (levels[applied - 1], applied)
    }

    /// Drops least recently used copies until the rest fit the budget. Call with the lock held.
    private func evict(keeping key: ObjectIdentifier) {
        var total = entries.values.reduce(0) { $0 + $1.pixels }
        while total > Self.pixelBudget,
              let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= oldest.value.pixels
            entries.removeValue(forKey: oldest.key)
        }
    }

    /// Exactly half the size, rounded up, with Lanczos resampling. Color images are padded with transparent
    /// pixels first, so edges fade out the same way wherever the image is cut; ringing past a pixel's alpha is
    /// clamped so edges don't glow. Gray masks repeat an odd last row or column instead.
    static func halve(_ image: CGImage) -> CGImage? {
        let mask = image.colorSpace?.model == .monochrome && image.alphaInfo == .none
        let width = (image.width + 1) / 2, height = (image.height + 1) / 2
        let pad = mask ? 0 : 8
        let paddedWidth = width * 2 + pad * 2, paddedHeight = height * 2 + pad * 2
        guard let source = try? BrushRaster.context(width: paddedWidth, height: paddedHeight, mask: mask),
              let destination = try? BrushRaster.context(width: paddedWidth / 2, height: paddedHeight / 2, mask: mask) else { return nil }
        source.clear(CGRect(x: 0, y: 0, width: paddedWidth, height: paddedHeight))
        let placed = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        BrushRaster.draw(image, in: placed, mask: mask, context: source)
        if mask {
            if paddedWidth > image.width, let column = image.cropping(to: CGRect(x: image.width - 1, y: 0, width: 1, height: image.height)) {
                BrushRaster.draw(column, in: CGRect(x: image.width, y: 0, width: 1, height: image.height), mask: true, context: source)
            }
            if paddedHeight > image.height, let row = source.makeImage()?.cropping(to: CGRect(x: 0, y: image.height - 1, width: paddedWidth, height: 1)) {
                BrushRaster.draw(row, in: CGRect(x: 0, y: image.height, width: paddedWidth, height: 1), mask: true, context: source)
            }
        }
        guard let from = source.data, let into = destination.data else { return nil }
        var input = vImage_Buffer(data: from, height: vImagePixelCount(paddedHeight), width: vImagePixelCount(paddedWidth),
                                  rowBytes: source.bytesPerRow)
        var output = vImage_Buffer(data: into, height: vImagePixelCount(paddedHeight / 2), width: vImagePixelCount(paddedWidth / 2),
                                   rowBytes: destination.bytesPerRow)
        let flags = vImage_Flags(kvImageHighQualityResampling)
        let error = mask ? vImageScale_Planar8(&input, &output, nil, flags) : vImageScale_ARGB8888(&input, &output, nil, flags)
        guard error == kvImageNoError else { return nil }
        if !mask { rgba_clamp_premultiplied(into.assumingMemoryBound(to: UInt8.self), (paddedWidth / 2) * (paddedHeight / 2)) }
        guard let halved = destination.makeImage() else { return nil }
        return mask ? halved : halved.cropping(to: CGRect(x: pad / 2, y: pad / 2, width: width, height: height))
    }
}
