import Foundation
import CoreGraphics

/// Immutable, normalized layer-local coverage. Regular grayscale images use white
/// for reveal, black for hide, and intermediate gray for soft coverage.
nonisolated struct LayerMask: Equatable, @unchecked Sendable {
    let asset: ImportedImage
    var isEnabled = true
    /// Where the mask sits on the document once it has been moved apart from its layer; nil while it covers the
    /// layer's own pixel grid (and follows every change to it).
    var placement: LayerTransform? = nil
    /// Linked, layer and mask move together; unlinked, each transforms on its own, as in Photoshop.
    var isLinked = true
    var enabledImage: CGImage? { isEnabled ? asset.image : nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.asset.image === rhs.asset.image && lhs.isEnabled == rhs.isEnabled && lhs.placement == rhs.placement && lhs.isLinked == rhs.isLinked
    }
    /// The same mask with new pixels (in its own grid), still enabled or not, linked or not, and where it sits.
    func replacing(_ asset: ImportedImage) -> LayerMask {
        LayerMask(asset: asset, isEnabled: isEnabled, placement: placement, isLinked: isLinked)
    }
    static func isValid(_ image: CGImage) -> Bool {
        !image.isMask && image.colorSpace?.model == .monochrome
            && image.bitsPerComponent == 8 && image.alphaInfo == .none
    }
    static func solid(revealing: Bool) -> LayerMask? {
        let data = Data([revealing ? UInt8(255) : UInt8(0)])
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return LayerMask(asset: ImportedImage(image: image, thumbnail: image, name: "Layer Mask"))
    }
    static func asset(from image: CGImage) throws -> ImportedImage {
        guard isValid(image) else { throw ProjectError.invalid }
        let factor = min(1, 96 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.render }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: bounds, mask: image)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        guard let thumbnail = context.makeImage() else { throw ExportError.render }
        return ImportedImage(image: image, thumbnail: thumbnail, name: "Layer Mask")
    }

    // MARK: Placement

    /// Where the mask sits once its layer moves from `old` to `new`: carried along when linked (still covering the
    /// layer, or its own placement moved the same way); left where it was on the document when unlinked.
    func placement(movingLayer old: LayerTransform, to new: LayerTransform) -> LayerTransform? {
        // A uniform mask looks the same wherever it sits.
        guard asset.image.width > 1 || asset.image.height > 1 else { return nil }
        let moved = isLinked ? placement.map { $0.following(from: old, to: new) } : (placement ?? old)
        return moved.flatMap { $0.samePlacement(as: new) ? nil : $0 }
    }

    /// What a mask shows beyond its pixels once placed apart from its layer: white or black, whichever most of its
    /// edge is (read from the small thumbnail) — so a reveal-all mask keeps revealing and a hide-all mask hiding.
    static func background(of thumbnail: CGImage) -> CGFloat {
        let width = thumbnail.width, height = thumbnail.height
        guard width > 0, height > 0, let context = try? BrushRaster.context(width: width, height: height, mask: true),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 1 }
        BrushRaster.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        var total = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where y == 0 || y == height - 1 || x == 0 || x == width - 1 {
                total += Int(data[y * context.bytesPerRow + x])
                count += 1
            }
        }
        return total * 2 >= count * 255 ? 1 : 0
    }

    /// A `width` × `height` gray grid stretched over a layer at `layer`, holding what `compose` draws in a
    /// `maskWidth` × `maskHeight` mask grid (y down) placed on the document by `placement`; `background` elsewhere.
    static func placed(width: Int, height: Int, layer: LayerTransform, placement: LayerTransform, maskWidth: Int, maskHeight: Int,
                       background: CGFloat, compose: (CGContext) -> Void) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(BrushRaster.pixelToDocument(placement, width: maskWidth, height: maskHeight)
            .concatenating(BrushRaster.pixelToDocument(layer, width: width, height: height).inverted()))
        context.interpolationQuality = .high
        compose(context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// `image`'s mask values drawn over `rect` (y down), resampled smoothly (`BrushRaster.draw` samples nearest).
    static func drawSmooth(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: rect.size)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.clip(to: bounds, mask: image)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.restoreGState()
    }

    /// The mask as a layer's renderers take it: an image stretched over the layer's `width` × `height` pixel grid at
    /// `layer`. Covering the layer (`placement` nil) that's the mask itself; placed apart, it is resampled into that
    /// grid — at most `limit` pixels across — and cached. Nil while disabled.
    func clipImage(placement: LayerTransform?, over layer: LayerTransform, width: Int, height: Int, limit: CGFloat? = nil) -> CGImage? {
        guard let image = enabledImage else { return nil }
        guard let placement, !placement.samePlacement(as: layer), width > 0, height > 0 else { return image }
        let factor = limit.map { min(1, max(1, $0) / CGFloat(max(width, height))) } ?? 1
        let w = max(1, Int((CGFloat(width) * factor).rounded(.up))), h = max(1, Int((CGFloat(height) * factor).rounded(.up)))
        let thumbnail = asset.thumbnail
        return MaskPlacementCache.shared.image(mask: image, placement: placement, layer: layer, width: w, height: h) {
            // Drawn from a sharp halving near the size the mask covers in the grid.
            let covered = placement.size.width / max(1, layer.size.width) * CGFloat(w)
            let source = DownsampleCache.shared.image(image, drawnAt: covered / CGFloat(image.width))
            return try? Self.placed(width: w, height: h, layer: layer, placement: placement, maskWidth: image.width,
                                    maskHeight: image.height, background: Self.background(of: thumbnail)) { context in
                Self.drawSmooth(source, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
            }
        }
    }
}

/// Masks resampled into their layers' grids (`LayerMask.clipImage`), so redraws reuse them; the least recently used
/// go beyond a few entries or a pixel budget.
nonisolated final class MaskPlacementCache: @unchecked Sendable {
    static let shared = MaskPlacementCache()
    private struct Entry {
        let mask: CGImage
        let placement: LayerTransform
        let layer: LayerTransform
        let width: Int
        let height: Int
        let image: CGImage
        var lastUse: UInt64
    }
    private var entries: [Entry] = []
    private var clock: UInt64 = 0
    private let lock = NSLock()

    func image(mask: CGImage, placement: LayerTransform, layer: LayerTransform, width: Int, height: Int, build: () -> CGImage?) -> CGImage? {
        lock.lock()
        clock += 1
        if let index = entries.firstIndex(where: { $0.mask === mask && $0.placement == placement && $0.layer == layer && $0.width == width && $0.height == height }) {
            entries[index].lastUse = clock
            let image = entries[index].image
            lock.unlock()
            return image
        }
        lock.unlock()
        guard let image = build() else { return nil }
        guard width * height <= 64_000_000 else { return image }
        lock.lock()
        entries.append(Entry(mask: mask, placement: placement, layer: layer, width: width, height: height, image: image, lastUse: clock))
        while entries.count > 8 || entries.reduce(0, { $0 + $1.width * $1.height }) > 64_000_000,
              let oldest = entries.indices.min(by: { entries[$0].lastUse < entries[$1].lastUse }) {
            entries.remove(at: oldest)
        }
        lock.unlock()
        return image
    }
}

/// A folder's mask, clipping the layers inside the folder. Folders are pass-through — the
/// layers inside are drawn straight onto what is below, never composited as a unit — so a
/// folder mask applies to each of those layers, multiplied with the layer's own mask and the
/// masks of any folders further out (Core Graphics multiplies nested mask clips).
nonisolated struct FolderMaskClip {
    let image: CGImage
    let transform: LayerTransform

    /// Intersects the context's clip with this mask, placed exactly as `LayerRenderer.draw`
    /// places a layer's own mask, and leaves the context's transform as it found it.
    func apply(scale: CGFloat = 1, center: CGPoint, in context: CGContext) {
        let width = transform.size.width * scale, height = transform.size.height * scale
        let placement = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: transform.radians)
            .scaledBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        context.interpolationQuality = transform.sampling.quality
        context.concatenate(placement)
        context.clip(to: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), mask: image)
        context.concatenate(placement.inverted())
    }

    /// Draws `ids` in order, each clipped by every folder containing it. `clip` says how to
    /// clip for one folder, or nil when it has no enabled mask, and is asked once per folder.
    static func draw(_ ids: [UUID], parent: (UUID) -> UUID?, clip: (UUID) -> ((CGContext) -> Void)?,
                     in context: CGContext, drawLayer: (UUID) -> Void) {
        var clips: [UUID: ((CGContext) -> Void)?] = [:]
        for id in ids {
            var appliers: [(CGContext) -> Void] = []
            var folder = parent(id), depth = 0
            while let current = folder, depth < 64 {
                if clips[current] == nil { clips[current] = .some(clip(current)) }
                if let apply = clips[current] ?? nil { appliers.append(apply) }
                folder = parent(current)
                depth += 1
            }
            guard !appliers.isEmpty else { drawLayer(id); continue }
            context.saveGState()
            appliers.forEach { $0(context) }
            drawLayer(id)
            context.restoreGState()
        }
    }
}

extension ProjectSnapshot {
    nonisolated func mask(for layer: ProjectLayerRecord) -> LayerMask? {
        guard layer.maskFile != nil, let asset = masks[layer.id] else { return nil }
        return LayerMask(asset: asset, isEnabled: layer.maskEnabled ?? true, placement: layer.maskPlacement, isLinked: layer.maskLinked ?? true)
    }
}

extension EditorSession {
    /// Layers and folders alike take a mask.
    var canEditMask: Bool { canEditLayers && selectedLayerIDs.count == 1 && activeLayer != nil }
    func selectLayerTarget(_ id: UUID, mask: Bool) {
        effectSelection = nil
        guard !isProjectBusy, !isImporting, brushStroke == nil else { return }
        resolveGradient()
        selectLayer(id)
        isMaskSelected = mask && activeLayer?.mask != nil
    }
    /// Adding a mask from the Layers panel (the footer button, or a layer's Add White/Black Mask):
    /// with no selection, a mask all white (reveal) or all black (hide); with a selection, that
    /// color with the selected area painted the opposite, so a white mask hides the selection. The
    /// selection is used up and deselected in the same undo step, as Photoshop does.
    func addMask(revealing: Bool = true) {
        guard let selection else { addLayerMask(revealing: revealing); return }
        guard canEditMask, let layer = activeLayer, layer.mask == nil,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        // Mask pixels cover the layer's own pixel grid, like every other mask.
        let width = layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let height = layer.asset?.image.height ?? Int(layer.size.height.rounded())
        do {
            guard width > 0, height > 0, width * height <= 100_000_000 else { throw ProjectError.tooLarge }
            let context = try BrushRaster.context(width: width, height: height, mask: true)
            context.setFillColor(gray: revealing ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let canvasSize = document?.size else { return }
            let clip = try selection.clip(canvas: canvasSize)
            context.concatenate(BrushRaster.pixelToDocument(layer.transform, width: width, height: height).inverted())
            clip.apply(to: context)
            context.setFillColor(gray: revealing ? 0 : 1, alpha: 1)
            context.fill(clip.rect)
            guard let image = context.makeImage() else { throw ExportError.render }
            let mask = LayerMask(asset: try LayerMask.asset(from: image))
            finishOpacityEdit()
            beginEdit(String(localized: "Add Mask from Selection"))
            document?.layers[index].mask = mask
            document?.selection = nil
            isMaskSelected = true
            endEdit()
        } catch { brushError = error.localizedDescription }
    }

    /// A plain all-white (reveal) or all-black (hide) mask, whatever is selected.
    func addLayerMask(revealing: Bool = true) {
        guard canEditMask, activeLayer?.mask == nil, let mask = LayerMask.solid(revealing: revealing),
              let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        finishOpacityEdit()
        beginEdit(revealing ? "Add Reveal-All Mask" : "Add Hide-All Mask")
        document?.layers[index].mask = mask
        isMaskSelected = true
        endEdit()
    }
    func toggleLayerMask() {
        guard canEditMask, activeLayer?.mask != nil,
              let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        finishOpacityEdit()
        beginEdit(activeLayer?.mask?.isEnabled == true ? "Disable Layer Mask" : "Enable Layer Mask")
        document?.layers[index].mask?.isEnabled.toggle()
        endEdit()
    }
    func deleteLayerMask() {
        guard canEditMask, activeLayer?.mask != nil,
              let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        finishOpacityEdit()
        beginEdit(String(localized: "Delete Layer Mask"))
        document?.layers[index].mask = nil
        isMaskSelected = false
        endEdit()
    }
    /// Whether an Option-drag can drop a copy of `source`'s mask on `target`.
    func canCopyMask(from source: UUID, to target: UUID) -> Bool {
        guard canEditLayers, source != target, let layers = document?.layers,
              layers.first(where: { $0.id == source })?.mask != nil,
              let layer = layers.first(where: { $0.id == target }) else { return false }
        return !layer.isGroup
    }
    /// Option-dragging a mask thumbnail onto another layer: a copy of the mask, sitting where it sits on the
    /// document, replacing any mask the layer had.
    func copyMask(from source: UUID, to target: UUID) {
        guard canCopyMask(from: source, to: target), let layers = document?.layers,
              let from = layers.first(where: { $0.id == source }), var mask = from.mask,
              let index = layers.firstIndex(where: { $0.id == target }) else { return }
        commitTransform()
        finishOpacityEdit()
        mask.placement = from.maskTransform
        beginEdit(layers[index].mask == nil ? "Copy Layer Mask" : "Replace Layer Mask")
        document?.layers[index].mask = mask
        selectLayer(target)
        isMaskSelected = true
        endEdit()
    }
    /// The link between a layer and its mask: linked they move together; unlinked each transforms on its own.
    func toggleMaskLink(_ id: UUID) {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let mask = document?.layers[index].mask else { return }
        commitTransform()
        finishOpacityEdit()
        beginEdit(mask.isLinked ? "Unlink Layer Mask" : "Link Layer Mask")
        document?.layers[index].mask?.isLinked.toggle()
        endEdit()
    }

    /// Where `layer`'s mask shows right now — nil while it covers the layer's (displayed) pixel grid: a pending
    /// mask transform's draft, or where a pending layer transform leaves it (carried along when linked).
    func displayedMaskPlacement(for layer: ImageLayer) -> LayerTransform? {
        guard let mask = layer.mask else { return nil }
        // Content-Aware Fill previewing on a grown layer: the mask keeps covering the layer's old bounds.
        if let edit = filterEdit, edit.grownTransform != nil, edit.previewImage(for: layer.id) != nil { return mask.placement ?? layer.transform }
        if let edit = transformEdit, let group = edit.group {
            guard let original = group.originals[layer.id] else { return mask.placement }
            if edit.corners != nil { return mask.isLinked && mask.placement == nil ? nil : mask.placement ?? layer.transform }
            return mask.placement(movingLayer: layer.transform, to: original.following(from: group.box, to: edit.draft))
        }
        guard let edit = transformEdit, edit.layerID == layer.id, edit.floating == nil else { return mask.placement }
        if edit.mask { return edit.draft.samePlacement(as: layer.transform) ? nil : edit.draft }
        // A distortion carries a mask covering a linked layer with it; any other mask stays put.
        if edit.corners != nil { return mask.isLinked && mask.placement == nil ? nil : mask.placement ?? layer.transform }
        return mask.placement(movingLayer: layer.transform, to: edit.draft)
    }

    /// Apply for an unlinked mask transformed on its own: it takes the new placement (its pixels untouched).
    func commitMaskTransform(_ edit: TransformEdit) {
        maskDistortPreviewCache = nil
        guard edit.draft.isValid, let index = document?.layers.firstIndex(where: { $0.id == edit.layerID }),
              let layer = document?.layers[index], let mask = layer.mask else { return }
        if let corners = edit.corners {
            // A distorted mask is resampled into the shape, over the shape's bounds, its background outside it.
            do {
                let moved = try DistortWarp.warpMask(mask.asset.image, transform: edit.draft, corners: corners,
                                                     background: LayerMask.background(of: mask.asset.thumbnail))
                let asset = moved.image === mask.asset.image ? mask.asset : try LayerMask.asset(from: moved.image)
                finishOpacityEdit()
                beginEdit(String(localized: "Distort Layer Mask"))
                document?.layers[index].mask = LayerMask(asset: asset, isEnabled: mask.isEnabled,
                    placement: moved.transform.samePlacement(as: layer.transform) ? nil : moved.transform, isLinked: mask.isLinked)
                endEdit()
            } catch { brushError = error.localizedDescription }
            return
        }
        let placement = edit.draft.samePlacement(as: layer.transform) ? nil : edit.draft
        guard placement != mask.placement else { return }
        finishOpacityEdit()
        beginEdit(String(localized: "Transform Layer Mask"))
        document?.layers[index].mask?.placement = placement
        endEdit()
    }
}

/// The canvas's last preview of an unlinked mask being distorted on its own.
struct MaskDistortPreviewCache {
    let corners: [CGPoint]
    let draft: LayerTransform
    let mask: CGImage
    let layer: LayerTransform
    let result: CGImage?
}

extension EditorSession {
    /// An unlinked mask being distorted on its own: the warped mask resampled into the layer's grid, for the canvas.
    func maskDistortPreview(for layer: ImageLayer) -> CGImage? {
        guard let edit = transformEdit, edit.mask, edit.layerID == layer.id, let corners = edit.corners,
              let owned = layer.mask, owned.isEnabled else { return nil }
        if let cache = maskDistortPreviewCache, cache.corners == corners, cache.draft == edit.draft,
           cache.mask === owned.asset.image, cache.layer == layer.transform { return cache.result }
        let width = layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let height = layer.asset?.image.height ?? Int(layer.size.height.rounded())
        let result = (try? DistortWarp.warpMask(owned.asset.image, transform: edit.draft, corners: corners,
                                                background: LayerMask.background(of: owned.asset.thumbnail), limit: 2048)).flatMap { moved in
            LayerMask(asset: ImportedImage(image: moved.image, thumbnail: owned.asset.thumbnail, name: owned.asset.name))
                .clipImage(placement: moved.transform, over: layer.transform, width: width, height: height, limit: 2048)
        }
        maskDistortPreviewCache = MaskDistortPreviewCache(corners: corners, draft: edit.draft, mask: owned.asset.image,
                                                          layer: layer.transform, result: result)
        return result
    }
}

extension ImageLayer {
    /// Where the mask's pixels sit on the document: its own placement, else the layer's.
    var maskTransform: LayerTransform { mask?.placement ?? transform }
}

extension BrushStroke {
    /// Painting a mask on its own placement (the stroke's grid is the mask's): the mask as the stroke leaves it,
    /// resampled into the layer's grid at preview size, for the canvas to draw the layer through.
    func placedMaskPreview(placement: LayerTransform) -> CGImage? {
        let gridWidth = layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let gridHeight = layer.asset?.image.height ?? Int(layer.size.height.rounded())
        let factor = min(1, 2048 / CGFloat(max(1, gridWidth, gridHeight)))
        let w = max(1, Int((CGFloat(gridWidth) * factor).rounded(.up))), h = max(1, Int((CGFloat(gridHeight) * factor).rounded(.up)))
        let old = layer.mask?.asset
        let perMaskPixel = placement.size.width / CGFloat(max(1, width)) * CGFloat(w) / max(1, layer.transform.size.width)
        return try? LayerMask.placed(width: w, height: h, layer: layer.transform, placement: placement, maskWidth: width, maskHeight: height,
                                     background: old.map { LayerMask.background(of: $0.thumbnail) } ?? 1) { context in
            if let old { LayerMask.drawSmooth(DownsampleCache.shared.image(old.image, drawnAt: perMaskPixel), in: sourceRect, context: context) }
            for patch in patches { LayerMask.drawSmooth(patch.image, in: patch.rect, context: context) }
        }
    }
}

