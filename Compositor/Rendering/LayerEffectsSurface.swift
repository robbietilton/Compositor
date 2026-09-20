import AppKit
import CoreImage

/// A layer's effects kept at full resolution while it is painted, and brought up to date only where the paint
/// changed. Rebuilding every effect over a whole layer for each dab is what made painting drag; the cost here
/// follows the brush instead, so a small brush on a big layer is cheap however large the layer is.
@MainActor final class LayerEffectsSurface {
    let layerID: UUID
    /// The grid the stroke paints in, in layer pixels, and where the layer's own pixels sit inside it.
    let grid: CGSize
    let sourceRect: CGRect
    /// The room the effects need around the pixels.
    let margin: CGFloat
    private let effects: LayerEffects
    private let context: CGContext
    private var shown: CGImage?
    /// Which tile images have already been taken in, so only new paint is redone.
    private var taken: [String: ObjectIdentifier] = [:]
    private(set) var image: CGImage?
    /// Where the surface was last drawn, so what it holds can be handed on when the stroke ends.
    var placement: LayerTransform?

    /// How far a pixel can reach into its surroundings: everything within this of a change may need redoing.
    private var reach: CGFloat {
        var reach: CGFloat = 1
        if let stroke = effects.stroke, stroke.isEnabled { reach = max(reach, stroke.size + 2) }
        if let shadow = effects.shadow, shadow.isEnabled { reach = max(reach, shadow.distance + shadow.blur * 3 + 2) }
        return ceil(reach)
    }

    init?(layerID: UUID, effects: LayerEffects, grid: CGSize, sourceRect: CGRect) {
        let margin = LayerEffectsRenderer.margin(for: effects)
        let width = Int(grid.width + margin * 2), height = Int(grid.height + margin * 2)
        guard width > 0, height > 0, width * height <= 80_000_000,
              let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        self.layerID = layerID
        self.effects = effects
        self.grid = grid
        self.sourceRect = sourceRect
        self.margin = margin
        self.context = context
    }

    /// Whether this surface still fits the stroke and settings it was made for.
    func matches(layerID: UUID, effects: LayerEffects, grid: CGSize, sourceRect: CGRect) -> Bool {
        self.layerID == layerID && self.effects == effects && self.grid == grid && self.sourceRect == sourceRect
    }

    /// Brings the surface up to date: everything on the first pass, and after that only where the paint changed.
    /// `base` is the layer's committed pixels and `patches` the stroke's tiles as they stand.
    func update(base: CGImage?, patches: [BrushPatch], mask: CGImage?) {
        var dirty: CGRect?
        var seen: [String: ObjectIdentifier] = [:]
        for patch in patches {
            let key = "\(Int(patch.rect.minX)),\(Int(patch.rect.minY))"
            seen[key] = ObjectIdentifier(patch.image)
            if taken[key] != ObjectIdentifier(patch.image) { dirty = dirty.map { $0.union(patch.rect) } ?? patch.rect }
        }
        let first = image == nil
        taken = seen
        let region = first ? CGRect(origin: .zero, size: grid).insetBy(dx: -margin, dy: -margin) : dirty
        guard let region else { return }
        compose(region.integral, base: base, patches: patches, mask: mask)
        image = context.makeImage()
    }

    /// Redraws one region of the surface: the effects there, then the pixels over them.
    private func compose(_ region: CGRect, base: CGImage?, patches: [BrushPatch], mask: CGImage?) {
        let bounds = CGRect(origin: .zero, size: grid).insetBy(dx: -margin, dy: -margin)
        let inner = region.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
        guard !inner.isNull, inner.width >= 1, inner.height >= 1 else { return }
        // Everything that can reach into `inner` has to be looked at.
        let outer = inner.insetBy(dx: -reach, dy: -reach).integral
        guard let pixels = window(outer, base: base, patches: patches, mask: mask) else { return }
        // In one pass on the GPU when it is available: the outline's reach and the shadow's blur are what cost.
        if let metal = MetalLayerEffects.shared, let built = try? metal.render(pixels, effects: effects) {
            context.saveGState()
            context.clip(to: inner.offsetBy(dx: margin, dy: margin))
            context.clear(inner.offsetBy(dx: margin, dy: margin))
            BrushRaster.draw(built, in: outer.offsetBy(dx: margin, dy: margin), mask: false, context: context)
            context.restoreGState()
            return
        }
        // In the surface's own coordinates, the grid starts at the margin.
        func placed(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: margin, dy: margin) }
        context.saveGState()
        context.clip(to: placed(inner))
        context.clear(placed(inner))
        if let shadow = effects.shadow, shadow.isEnabled, shadow.opacity > 0,
           let coverage = try? LayerEffectsRenderer.shadowCoverage(pixels, in: outer.size, offset: shadow.offset, blur: shadow.blur) {
            fill(shadow.color, alpha: shadow.opacity, coverage: coverage, in: placed(outer))
        }
        let stroke = effects.stroke.flatMap { $0.isEnabled && $0.size > 0 && $0.opacity > 0 ? $0 : nil }
        if let stroke, !stroke.inside, let ring = try? LayerEffectsRenderer.ringCoverage(pixels, in: outer.size, stroke: stroke) {
            fill(stroke.color, alpha: stroke.opacity, coverage: ring, in: placed(outer))
        }
        BrushRaster.draw(pixels, in: placed(outer), mask: false, context: context)
        if let stroke, stroke.inside, let ring = try? LayerEffectsRenderer.ringCoverage(pixels, in: outer.size, stroke: stroke) {
            fill(stroke.color, alpha: stroke.opacity, coverage: ring, in: placed(outer))
        }
        context.restoreGState()
    }

    /// The layer as the stroke has it, over one region: its committed pixels, the tiles painted since, and its mask.
    private func window(_ region: CGRect, base: CGImage?, patches: [BrushPatch], mask: CGImage?) -> CGImage? {
        guard region.width >= 1, region.height >= 1,
              let window = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false) else { return nil }
        window.translateBy(x: -region.minX, y: -region.minY)
        func drawPixels() {
            if let base { BrushRaster.draw(base, in: sourceRect, mask: false, context: window) }
            for patch in patches where patch.rect.intersects(region) {
                BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: window)
            }
        }
        if let mask {
            // The layer's own pixels are shown through its mask; paint laid down past them is not masked at all.
            window.saveGState()
            window.clip(to: sourceRect, mask: mask)
            drawPixels()
            window.restoreGState()
            window.saveGState()
            let outside = CGMutablePath()
            outside.addRect(region)
            outside.addRect(sourceRect)
            window.addPath(outside)
            window.clip(using: .evenOdd)
            drawPixels()
            window.restoreGState()
        } else {
            drawPixels()
        }
        return window.makeImage()
    }

    private func fill(_ color: PaletteColor, alpha: Double, coverage: CGImage, in rect: CGRect) {
        context.saveGState()
        context.clip(to: rect, mask: coverage)
        context.setAlpha(alpha)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.fill(rect)
        context.restoreGState()
    }
}
