import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a generated layer sits and what of it shows. The models repaint the whole picture they are sent,
/// so the layer keeps only the target: its mask is the selection, grown a little and softened, which hides
/// the seam where generated pixels meet the ones underneath.
nonisolated struct GenerativeMask: @unchecked Sendable {
    /// Whole document pixels the layer covers.
    let rect: CGRect
    /// 8-bit gray coverage the size of `rect`: white shows the generated pixels.
    let coverage: CGImage

    /// - Parameters:
    ///   - grow: how far past the outline the generated pixels reach, so an object's fringe goes with it.
    ///   - feather: how softly they fade out from there.
    ///   - limit: the layer never reaches past this: the sampled region, within the canvas.
    static func make(_ selection: DocumentSelection, grow: CGFloat, feather: CGFloat, limit: CGRect) throws -> GenerativeMask? {
        var path = selection.path
        if grow > 0 {
            let band = path.copy(strokingWithWidth: grow * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            path = path.union(band, using: .winding)
        }
        let soft = DocumentSelection(path: path, antialiased: selection.antialiased, feather: feather)
        let rect = soft.coverageBounds.insetBy(dx: -1, dy: -1).integral.intersection(limit.integral)
        guard !soft.isEmpty, !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        var toLayer = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        guard let local = path.copy(using: &toLayer) else { throw ExportError.render }
        let coverage = try DocumentSelection(path: local, antialiased: selection.antialiased, feather: feather)
            .coverage(width: Int(rect.width), height: Int(rect.height))
        return GenerativeMask(rect: rect, coverage: coverage)
    }
}

nonisolated enum GenerativeRaster {
    /// A smooth resample of `image`, or of the `source` part of it (top-left pixel coordinates), to `size`.
    /// The part may fall between pixels: it is placed by a transform, never rounded to a crop, because a
    /// generated patch that lands a pixel off shows as a seam.
    static func resized(_ image: CGImage, from source: CGRect? = nil, to size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        let part = source ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard part.width > 0, part.height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        // This context keeps Core Graphics' bottom-left origin, so the part's top edge is measured from below.
        let sx = CGFloat(width) / part.width, sy = CGFloat(height) / part.height
        context.draw(image, in: CGRect(x: -part.minX * sx, y: -(CGFloat(image.height) - part.maxY) * sy,
                                       width: CGFloat(image.width) * sx, height: CGFloat(image.height) * sy))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// The generated pixels for the layer: the part of the model's answer that stands for `rect`, at the
    /// document's scale. Mapped by fractions, because the answer comes back at a size of the model's choosing.
    static func layerImage(from returned: CGImage, plan: GenerativePlan, rect: CGRect) throws -> CGImage {
        let whole = plan.source(in: CGSize(width: returned.width, height: returned.height))
        let sx = whole.width / plan.region.width, sy = whole.height / plan.region.height
        let part = CGRect(x: whole.minX + (rect.minX - plan.region.minX) * sx, y: whole.minY + (rect.minY - plan.region.minY) * sy,
                          width: rect.width * sx, height: rect.height * sy)
        return try resized(returned, from: part, to: rect.size)
    }

    /// True when any pixel lets what is behind it through. Such a picture has to travel as PNG.
    static func hasTransparency(_ image: CGImage) throws -> Bool {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return false }
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let data = context.data else { throw ExportError.render }
        let pixels = data.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        for row in 0..<image.height {
            let line = pixels + row * stride
            for column in 0..<image.width where line[column * 4 + 3] != 255 { return true }
        }
        return false
    }

    /// What the model is sent: JPEG for a solid picture, which keeps a large crop within the request limit,
    /// and PNG wherever transparency has to survive.
    static func encoded(_ image: CGImage) throws -> (data: Data, mimeType: String) {
        try hasTransparency(image) ? (encode(image, as: .png), "image/png") : (encode(image, as: .jpeg, quality: 0.92), "image/jpeg")
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw ExportError.render }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.render }
        return data as Data
    }

    /// A picture the size of the one sent, white where the change is wanted and black elsewhere. The models
    /// take no mask; shown one as a second picture, they place the change better than from words alone.
    static func hint(for selection: DocumentSelection, plan: GenerativePlan) throws -> CGImage {
        let width = Int(plan.sendSize.width), height = Int(plan.sendSize.height)
        var toSent = CGAffineTransform(translationX: -plan.region.minX, y: -plan.region.minY)
            .concatenating(CGAffineTransform(scaleX: plan.sendSize.width / plan.region.width, y: plan.sendSize.height / plan.region.height))
        guard let path = selection.path.copy(using: &toSent) else { throw ExportError.render }
        return try DocumentSelection(path: path, antialiased: true).coverage(width: width, height: height)
    }
}
