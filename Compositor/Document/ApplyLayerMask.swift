import CoreGraphics
import Foundation

extension EditorSession {
    /// Applying only makes sense for a raster layer carrying an enabled mask — not a group or an adjustment,
    /// which have no pixels of their own, and not a layer still live as text or a shape, where baking would
    /// throw away its editable source. Photoshop asks before applying a disabled mask; here it's simply left off.
    var canApplyLayerMask: Bool {
        guard canEditMask, let layer = activeLayer, let mask = layer.mask, mask.isEnabled,
              !layer.isGroup, layer.adjustment == nil, layer.asset != nil else { return false }
        return layer.liveText == nil && layer.liveShape == nil
    }

    /// Bakes the mask into the layer's own pixels — at the layer's native resolution, not the size it's scaled
    /// to on the document — then removes it. Reuses `clipImage`, which already resamples a moved mask through its
    /// own placement into the layer's grid (background beyond its edge included) and simply returns a mask that
    /// still covers the layer's grid as it is, stretched or not.
    func applyLayerMask() {
        guard canApplyLayerMask, let layer = activeLayer, let mask = layer.mask, let image = layer.asset?.image,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }),
              let coverage = mask.clipImage(placement: mask.placement, over: layer.transform, width: image.width, height: image.height)
        else { return }
        do {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: bounds, mask: coverage)
            context.draw(image, in: bounds)
            guard let baked = context.makeImage() else { throw ExportError.render }
            let thumbnail = try PixelAdjust.thumbnail(of: baked)
            finishOpacityEdit()
            beginEdit("Apply Layer Mask")
            document?.layers[index].asset = ImportedImage(image: baked, thumbnail: thumbnail, name: layer.asset?.name ?? layer.name)
            document?.layers[index].mask = nil
            isMaskSelected = false
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
