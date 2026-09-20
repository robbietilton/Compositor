import AppKit

nonisolated enum ContentFill {
    enum Failure: LocalizedError {
        case noSource
        var errorDescription: String? { L10n.string("Not enough unselected, opaque image pixels to synthesize a fill. Use a smaller selection with some surrounding image.") }
    }
    static func run(_ job: FilterJob) throws -> CGImage {
        guard let selection = job.selection else { throw Failure.noSource }
        let w=job.image.width, h=job.image.height
        let pixels = try BrushRaster.context(width: w, height: h, mask: false)
        let mask = try BrushRaster.context(width: w, height: h, mask: true)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        BrushRaster.draw(job.image, in: rect, mask: false, context: pixels)
        mask.saveGState()
        mask.concatenate(job.mapping.inverted())
        selection.apply(to: mask)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(rect.applying(job.mapping))
        mask.restoreGState()
        let result = content_fill(pixels.data!.assumingMemoryBound(to: UInt8.self), pixels.bytesPerRow,
            mask.data!.assumingMemoryBound(to: UInt8.self), mask.bytesPerRow, Int32(w), Int32(h))
        guard result != 0 else { throw Failure.noSource }
        guard result == 1, let image = pixels.makeImage() else { throw ExportError.render }
        return image
    }
}
