import Foundation
import CoreGraphics
import CoreImage

/// Per-render dependency cache. Coverage uses source alpha including its own masks,
/// independent of source visibility and color. Only the current clipped region is allocated.
nonisolated final class LiveMaskRenderer {
    let bounds: CGRect
    let source: (UUID) -> UUID?
    let drawOwn: (UUID, CGContext) -> Void
    private var cache: [UUID: CGImage] = [:]
    private var visiting = Set<UUID>()
    private var stacks: [UUID: [UUID]] = [:]
    private var stacked = Set<UUID>()
    private var stackModes: [UUID: LayerBlendMode] = [:]
    private var blendMode: (UUID) -> LayerBlendMode = { _ in .normal }
    var adjustment: (UUID) -> LayerAdjustment? = { _ in nil }
    var adjustmentOpacity: (UUID) -> Double = { _ in 1 }
    var adjustmentClip: (UUID, CGContext) -> Void = { _, _ in }
    var adjustmentScale: CGFloat = 1
    /// The part of the document `bounds` shows, when the context isn't laid out in document pixels (the canvas), so
    /// Grain's and Add Noise's patterns stay with the document.
    var adjustmentRegion: ((CGRect) -> CGRect)?
    /// Pixels per unit of `bounds` for the surfaces made along the way (a clipping stack, a coverage): the screen's, on
    /// the canvas, so they're as sharp as what they're drawn into.
    var resolution: CGFloat = 1
    /// `bounds` in the surfaces' pixels, and whether a surface that size is allowed.
    private var pixelSize: (width: Int, height: Int)? {
        let w = Int((bounds.width * resolution).rounded()), h = Int((bounds.height * resolution).rounded())
        guard w > 0, h > 0, CGFloat(w * h) <= DocumentLimits.maxSurfaceExtent else { return nil }
        return (w, h)
    }
    private func adjust(_ id: UUID, in context: CGContext) {
        guard let settings = adjustment(id), let original = context.makeImage(),
              var adjusted = try? settings.apply(original, region: adjustmentRegion?(bounds) ?? bounds, scale: adjustmentScale) else { return }
        if blendMode(id) != .normal {
            // Blend colors at full coverage, then restore the original alpha.
            // Source-over of two translucent copies would thicken soft edges.
            let w = original.width, h = original.height
            guard let base = try? BrushRaster.context(width: w, height: h, mask: false),
                  let top = try? BrushRaster.context(width: w, height: h, mask: false),
                  let alpha = try? BrushRaster.context(width: w, height: h, mask: true) else { return }
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            BrushRaster.draw(original, in: rect, mask: false, context: base)
            BrushRaster.draw(adjusted, in: rect, mask: false, context: top)
            let pixels = base.data!.assumingMemoryBound(to: UInt8.self)
            let coverage = alpha.data!.assumingMemoryBound(to: UInt8.self)
            layer_extract_alpha(pixels, base.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
            layer_unpremultiply_opaque(pixels, base.bytesPerRow, w, h)
            layer_unpremultiply_opaque(top.data!.assumingMemoryBound(to: UInt8.self), top.bytesPerRow, w, h)
            guard let foreground = top.makeImage() else { return }
            // Core Graphics has no Linear Dodge and the like, and gets Color Burn and Dodge wrong (see SeparableBlend).
            if !SeparableBlend.blend(foreground, over: base, mode: blendMode(id)) {
                base.setBlendMode(blendMode(id).cgMode)
                base.translateBy(x: 0, y: CGFloat(h)); base.scaleBy(x: 1, y: -1)
                base.draw(foreground, in: rect)
            }
            layer_restore_alpha(pixels, base.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
            guard let result = base.makeImage() else { return }
            adjusted = result
        }
        let opacity = adjustmentOpacity(id)
        let image: CGImage
        if opacity < 1 {
            let blend = CIImage(cgImage: adjusted).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(cgImage: original),
                kCIInputMaskImageKey: CIImage(color: CIColor(red: opacity, green: opacity, blue: opacity)).cropped(to: CIImage(cgImage: original).extent)])
            guard let result = try? PixelAdjust.render(blend, width: original.width, height: original.height, isMask: false) else { return }
            image = result
        } else { image = adjusted }
        context.saveGState()
        adjustmentClip(id, context)
        BrushRaster.draw(image, in: bounds, mask: false, context: context)
        context.restoreGState()
    }
    /// Clipping stacks share the base's alpha instead of painting that
    /// alpha over itself. Other dependency links retain independent-mask behavior.
    func prepareStacks(_ ids: [UUID], parent: (UUID) -> UUID?, blend: (UUID) -> LayerBlendMode) {
        let modes = Dictionary(uniqueKeysWithValues: ids.map { ($0, blend($0)) })
        blendMode = { modes[$0] ?? .normal }
        for (index, base) in ids.enumerated() where source(base) == nil && adjustment(base) == nil {
            var children: [UUID] = []
            for child in ids.dropFirst(index + 1) {
                guard source(child) == base, parent(child) == parent(base) else { break }
                children.append(child)
            }
            guard !children.isEmpty else { continue }
            stacks[base] = children
            stackModes[base] = blend(base)
            stacked.formUnion(children)
        }
    }
    func drawComposite(_ id: UUID, in context: CGContext) {
        guard !stacked.contains(id) else { return }
        if adjustment(id) != nil {
            if source(id) == nil { adjust(id, in: context) }
            return
        }
        guard let children = stacks[id], let (w, h) = pixelSize,
              let group = try? BrushRaster.context(width: w, height: h, mask: false),
              let alpha = try? BrushRaster.context(width: w, height: h, mask: true) else {
            if let children = stacks[id] { stacked.subtract(children) }
            draw(id, in: context); return
        }
        group.scaleBy(x: resolution, y: resolution)
        group.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawOwn(id, group)
        let pixels = group.data!.assumingMemoryBound(to: UInt8.self)
        let coverage = alpha.data!.assumingMemoryBound(to: UInt8.self)
        layer_extract_alpha(pixels, group.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
        layer_unpremultiply_opaque(pixels, group.bytesPerRow, w, h)
        for child in children {
            if adjustment(child) != nil { adjust(child, in: group) }
            else { drawOwn(child, group) }
        }
        layer_restore_alpha(pixels, group.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
        if let image = group.makeImage() {
            let bounds = bounds
            func place(_ target: CGContext) {
                target.saveGState()
                target.translateBy(x: bounds.minX, y: bounds.maxY)
                target.scaleBy(x: 1, y: -1)
                target.draw(image, in: CGRect(origin: .zero, size: bounds.size))
                target.restoreGState()
            }
            // The stack blends in its base's mode — through Core Image for the ones Core Graphics can't draw (Linear
            // Dodge and the rest), which it would otherwise draw as Normal.
            let mode = stackModes[id] ?? .normal
            if !(SeparableBlend.needsSurface(mode) && SeparableBlend.draw(mode, in: context, body: place)) {
                context.saveGState()
                context.setBlendMode(mode.cgMode)
                place(context)
                context.restoreGState()
            }
        }
    }
    init(bounds: CGRect, source: @escaping (UUID) -> UUID?, drawOwn: @escaping (UUID, CGContext) -> Void) {
        self.bounds = bounds.integral; self.source = source; self.drawOwn = drawOwn
    }
    func draw(_ id: UUID, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let sourceID = source(id) {
            guard let coverage = coverage(sourceID) else { return }
            // CGImage rows are top-down; CGContext image clipping is bottom-up.
            context.translateBy(x: 0, y: bounds.minY * 2 + bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: bounds, mask: coverage)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -(bounds.minY * 2 + bounds.height))
        }
        drawOwn(id, context)
    }
    private func coverage(_ id: UUID) -> CGImage? {
        if let image = cache[id] { return image }
        guard !visiting.contains(id), visiting.count < 256, let (w, h) = pixelSize else { return nil }
        visiting.insert(id); defer { visiting.remove(id) }
        guard let pixels = try? BrushRaster.context(width: w, height: h, mask: false),
              let gray = try? BrushRaster.context(width: w, height: h, mask: true) else { return nil }
        pixels.scaleBy(x: resolution, y: resolution)
        pixels.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(id, in: pixels)
        let rgba = pixels.data!.assumingMemoryBound(to: UInt8.self)
        let alpha = gray.data!.assumingMemoryBound(to: UInt8.self)
        layer_extract_alpha(rgba, pixels.bytesPerRow, alpha, gray.bytesPerRow, w, h)
        let image = gray.makeImage()
        cache[id] = image
        return image
    }
}
