import CoreImage
import Foundation
import UIKit

/// The iPad canvas's frame, composited on the GPU the way the Mac canvas composites its own.
///
/// Adapted from `CanvasView`'s GPU drawing in Rendering/EditorCanvas.swift, which lives inside the AppKit view for
/// now. Once that compositing moves out of the view, both canvases draw from it and this copy goes.
@MainActor final class PadCanvasCompositor {
    let session: EditorSession
    /// Called when something drawn in the background (a layer's effects) is ready to be shown.
    var needsRedraw: () -> Void = {}
    /// Where the text editor shows the text being typed, which the canvas draws it at.
    var textShownTransform: () -> LayerTransform? = { nil }
    private var strokeSurface: LayerEffectsSurface?
    private lazy var textRendering = TextDraftRendering(session: session)

    init(session: EditorSession) {
        self.session = session
    }

    /// The whole view — the backdrop, the document's shadow and checkerboard, the layers and the document's edge — in
    /// screen pixels, `size` across. Nil when a layer needs something the GPU path doesn't draw.
    func frame(_ document: CanvasDocument, renderer: GPUCanvasRenderer, size: CGSize) -> CIImage? {
        textRendering.handOffEffects(document)
        let viewport = session.viewport
        let device = viewport.backingScale
        let pixels = renderBounds ?? CGRect(origin: .zero, size: document.size)
        let origin = viewport.documentRect(document.size).origin
        let perPixel = viewport.pointsPerPixel * device
        let mapping = CGAffineTransform(a: perPixel, b: 0, c: 0, d: perPixel, tx: origin.x * device, ty: origin.y * device)
        let full = CGRect(origin: .zero, size: size)
        let rect = pixels.applying(mapping)
        func gray(_ white: CGFloat, alpha: CGFloat = 1) -> CIImage {
            CIImage(color: CIColor(red: white, green: white, blue: white, alpha: alpha))
        }
        var frame = gray(0.105).cropped(to: full)
        guard rect.intersects(full) else { return frame }
        // The document's shadow, then its checkerboard: 10-point squares from its top-left corner.
        let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: 0, y: 3 * device)).applyingGaussianBlur(sigma: 7 * device)
        frame = shadow.composited(over: frame)
        let tile = 10 * device
        let squares = gray(0.35).cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
            .composited(over: gray(0.30).cropped(to: CGRect(x: tile, y: 0, width: tile, height: tile)))
            .composited(over: gray(0.30).cropped(to: CGRect(x: 0, y: tile, width: tile, height: tile)))
            .composited(over: gray(0.35).cropped(to: CGRect(x: tile, y: tile, width: tile, height: tile)))
        let offset = NSValue(cgAffineTransform: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let checkerboard = squares.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: offset]).cropped(to: rect)
        frame = checkerboard.composited(over: frame)
        // From 200% the document's own pixels are composited one to one and enlarged as crisp squares.
        let crisp = viewport.zoom >= Self.crispZoom
        let placement = GPUPlacement(mapping: crisp ? .identity : mapping, scale: crisp ? 1 : perPixel, renderer: renderer)
        guard var layers = layers(document, placement: placement) else { return nil }
        if crisp { layers = layers.cropped(to: pixels).samplingNearest().transformed(by: mapping) }
        frame = layers.cropped(to: rect).composited(over: frame)
        // The document's edge: a one-pixel line centered on it.
        let edge = gray(1, alpha: 0.13)
        for line in [CGRect(x: rect.minX - 0.5, y: rect.minY - 0.5, width: rect.width + 1, height: 1),
                     CGRect(x: rect.minX - 0.5, y: rect.maxY - 0.5, width: rect.width + 1, height: 1),
                     CGRect(x: rect.minX - 0.5, y: rect.minY + 0.5, width: 1, height: rect.height - 1),
                     CGRect(x: rect.maxX - 0.5, y: rect.minY + 0.5, width: 1, height: rect.height - 1)] {
            frame = edge.cropped(to: line).composited(over: frame)
        }
        return frame.cropped(to: full)
    }

    /// From 200% (2 screen pixels per document pixel) the canvas shows hard-edged document pixels, as on the Mac.
    static let crispZoom: CGFloat = 2

    private var renderBounds: CGRect? {
        guard let document = session.document else { return nil }
        let original = CGRect(origin: .zero, size: document.size)
        return session.tool == .crop ? original.union(session.cropRect ?? original) : original
    }

    /// The raster edit painting this folder's mask, if one is in progress.
    private func liveMaskEdit(for id: UUID) -> BrushStroke? {
        [session.brushStroke, session.gradientEdit?.raster].compactMap { $0 }.first { $0.layer.id == id && $0.isMask }
    }

    /// The layers composited as the Mac canvas composites them, over nothing. Nil when a layer needs the Core Graphics
    /// canvas.
    private func layers(_ document: CanvasDocument, placement: GPUPlacement) -> CIImage? {
        session.effectsPreviews.prepare(layers: document.layers)
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let ids = document.renderLayers.map(\.id)
        // Clipping stacks, as `LiveMaskRenderer.prepareStacks` finds them.
        var stacks: [UUID: [UUID]] = [:], stacked = Set<UUID>()
        for (index, base) in ids.enumerated() where byID[base]?.maskSourceID == nil && byID[base]?.adjustment == nil {
            var children: [UUID] = []
            for child in ids.dropFirst(index + 1) {
                guard byID[child]?.maskSourceID == base, byID[child]?.parentID == byID[base]?.parentID else { break }
                children.append(child)
            }
            guard !children.isEmpty else { continue }
            stacks[base] = children
            stacked.formUnion(children)
        }
        // Folder masks, placed once each.
        var folderMasks: [UUID: CIImage?] = [:]
        func folderMask(_ id: UUID) -> CIImage? {
            if let known = folderMasks[id] { return known }
            let placed: CIImage? = byID[id].flatMap { folder in
                guard let mask = folder.mask, mask.isEnabled else { return nil }
                if let edit = liveMaskEdit(for: id) { return paintedMask(edit) }
                return placement.place(mask.asset.image, transform: session.displayedTransform(for: folder), mask: true)
            }
            folderMasks[id] = placed
            return placed
        }
        func clippedByFolders(_ id: UUID, _ image: CIImage) -> CIImage {
            var result = image, folder = byID[id]?.parentID, depth = 0
            while let current = folder, depth < 64 {
                if let mask = folderMask(current) { result = GPUBlend.masked(result, by: mask) }
                folder = byID[current]?.parentID
                depth += 1
            }
            return result
        }
        var unsupported = false
        // The old pixels of a layer being painted — or of its mask, painting the mask — as they were when it started.
        func oldPixels(_ stroke: BrushStroke) -> CIImage? {
            let asset = stroke.isMask ? stroke.layer.mask?.asset : stroke.layer.asset
            if let raster = asset?.raster { return placement.renderer.image(raster) }
            return asset.flatMap { placement.renderer.image($0.image, mask: stroke.isMask) }
        }
        // A mask being painted, as its stroke's grid: its old values (revealing past them) with the stroke's tiles, or a
        // gradient over them as it's dragged.
        func maskGrid(_ stroke: BrushStroke) -> CIImage? {
            guard let edit = session.gradientEdit, edit.raster === stroke else {
                return placement.renderer.image(stroke, base: oldPixels(stroke))
            }
            let gridRect = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            var grid = CIImage(color: .white).cropped(to: gridRect)
            if let old = oldPixels(stroke) { grid = inGrid(old, stroke: stroke).composited(over: grid) }
            if edit.hasLine, let fill = edit.fill, let shading = gradient(fill, stroke: stroke) { grid = shading.composited(over: grid) }
            return grid.cropped(to: gridRect)
        }
        func paintedMask(_ stroke: BrushStroke) -> CIImage? {
            guard let grid = maskGrid(stroke) else { return nil }
            return placement.place(live: grid, width: stroke.width, height: stroke.height, transform: stroke.paintTransform)
        }
        // An image covering the layer's old pixels, laid into the stroke's grid where they sit.
        func inGrid(_ image: CIImage, stroke: BrushStroke) -> CIImage {
            let source = stroke.sourceRect
            return image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: source.width / image.extent.width, y: source.height / image.extent.height)
                .concatenating(CGAffineTransform(translationX: source.minX, y: source.minY))).cropped(to: source)
        }
        // The layer's own mask while its pixels are painted, resampled into its grid when it's placed apart.
        func paintingMask(_ layer: ImageLayer, stroke: BrushStroke) -> CGImage? {
            guard let owned = layer.mask else { return nil }
            guard let maskPlacement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
            let base = stroke.layer.transform
            let drawn = max(base.size.width, base.size.height) * placement.scale
            let steady = pow(2, ceil(log2(max(64, drawn))))
            return owned.clipImage(placement: maskPlacement, over: base,
                width: stroke.layer.asset?.image.width ?? Int(base.size.width.rounded()),
                height: stroke.layer.asset?.image.height ?? Int(base.size.height.rounded()),
                limit: session.transformEdit != nil ? min(2048, steady) : steady)
        }
        // A mask shown by itself: gray across the canvas (its edge tone past its pixels), with a stroke being laid in.
        if let layer = session.maskAloneLayer, let mask = layer.mask {
            let edge = LayerMask.background(of: mask.asset.thumbnail)
            let back = CIImage(color: CIColor(red: edge, green: edge, blue: edge))
                .cropped(to: CGRect(origin: .zero, size: document.size).applying(placement.mapping))
            let placed: CIImage?
            if let stroke = session.brushStroke ?? session.gradientEdit?.raster, stroke.isMask, stroke.layer.id == layer.id {
                placed = paintedMask(stroke)
            } else {
                placed = placement.place(mask.asset.image, transform: session.displayedMaskPlacement(for: layer)
                    ?? session.displayedTransform(for: layer), mask: true)
            }
            // A mask's values are in its red channel; shown, they're gray.
            let gray = placed?.applyingFilter("CIColorMatrix", parameters: ["inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                                                                            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
            return gray.map { $0.composited(over: back) } ?? back
        }
        // A layer being painted: its grid as the stroke leaves it, through its own mask where its old pixels were.
        func painted(_ layer: ImageLayer, stroke: BrushStroke, opacity: Double) -> CIImage? {
            let gridRect = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            let placedApart = stroke.isMask && stroke.layer.mask?.placement != nil
            // A mask on its own placement paints in its own grid; the layer draws where it is.
            let transform = placedApart ? session.displayedTransform(for: layer) : stroke.paintTransform
            // With effects, they're redone as it's painted, from the stroke's tiles.
            if layer.effects?.visible.isEmpty == false {
                if let edit = session.gradientEdit, edit.raster === stroke { try? edit.applyFill() }
                if let move = session.pixelMove, move.raster === stroke { try? move.applyOffset() }
                let surface: LayerEffectsSurface?
                if placedApart, let maskPlacement = stroke.layer.mask?.placement {
                    surface = stroke.placedMaskPreview(placement: stroke.paintTransform).flatMap {
                        placedMaskSurface(layer: layer, stroke: stroke, placement: maskPlacement, preview: $0)
                    }
                } else {
                    surface = strokeSurface(layer: layer, stroke: stroke, mask: stroke.isMask ? nil : paintingMask(layer, stroke: stroke))
                }
                if let surface, let built = surface.image {
                    let grown = LayerEffectsRenderer.placed(transform, image: built, inset: surface.margin)
                    surface.placement = grown
                    guard let image = placement.place(transient: built, transform: grown) else { return nil }
                    return GPUBlend.faded(image, opacity)
                }
            }
            // Painting a mask placed apart: the layer where it is, through the mask as the stroke leaves it.
            if placedApart {
                let pixels: CIImage?
                if let raster = layer.asset?.raster { pixels = placement.place(raster, transform: transform) }
                else { pixels = layer.asset.flatMap { placement.place($0.image, transform: transform) } }
                guard var image = pixels else { return nil }
                if let preview = stroke.placedMaskPreview(placement: stroke.paintTransform) {
                    guard let mask = placement.place(transient: preview, transform: transform, mask: true) else { return nil }
                    image = GPUBlend.masked(image, by: mask)
                }
                return GPUBlend.faded(image, opacity)
            }
            var grid: CIImage
            if stroke.isMask {
                guard let mask = maskGrid(stroke) else { return nil }
                let pixels: CIImage?
                if let raster = layer.asset?.raster { pixels = placement.renderer.image(raster) }
                else { pixels = layer.asset.flatMap { placement.renderer.image($0.image) } }
                guard let pixels else { return nil }
                grid = GPUBlend.masked(inGrid(pixels, stroke: stroke), by: mask)
            } else if let edit = session.gradientEdit, edit.raster === stroke {
                grid = oldPixels(stroke).map { inGrid($0, stroke: stroke) } ?? CIImage.empty()
                if edit.hasLine, let fill = edit.fill, let fillImage = gradient(fill, stroke: stroke) {
                    grid = fillImage.composited(over: grid)
                }
                grid = grid.cropped(to: gridRect)
            } else {
                guard let image = placement.renderer.image(stroke, base: oldPixels(stroke)) else { return nil }
                grid = image
            }
            // The layer's own mask covers where its old pixels were.
            if !stroke.isMask, let mask = paintingMask(layer, stroke: stroke), let placed = placement.renderer.image(mask, mask: true) {
                grid = GPUBlend.masked(grid, by: inGrid(placed, stroke: stroke).composited(over: CIImage(color: .white).cropped(to: gridRect)))
            }
            guard let image = placement.place(live: grid, width: stroke.width, height: stroke.height, transform: transform)
            else { return nil }
            return GPUBlend.faded(image, opacity)
        }
        // A gradient fill in the stroke's grid: over the canvas and the selection, at the fill's opacity.
        func gradient(_ fill: GradientEdit.Fill, stroke: BrushStroke) -> CIImage? {
            func color(_ value: CGColor) -> CIColor {
                let c = value.colorSpace?.model == .monochrome ? value.components ?? [0, 1]
                    : value.converted(to: placement.renderer.space, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
                return CIColor(red: c[0], green: c.count > 2 ? c[1] : c[0], blue: c.count > 2 ? c[2] : c[0], alpha: c.last ?? 1,
                               colorSpace: placement.renderer.space) ?? .black
            }
            guard fill.colors.count == 2 else { return nil }
            let shading: CIImage
            switch fill.shape {
            case .linear:
                shading = CIImage.empty().applyingFilter("CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: fill.start), "inputPoint1": CIVector(cgPoint: fill.end),
                    "inputColor0": color(fill.colors[0]), "inputColor1": color(fill.colors[1])])
            case .radial:
                shading = CIImage.empty().applyingFilter("CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: fill.start), "inputRadius0": 0,
                    "inputRadius1": hypot(fill.end.x - fill.start.x, fill.end.y - fill.start.y),
                    "inputColor0": color(fill.colors[0]), "inputColor1": color(fill.colors[1])])
            }
            let toGrid = stroke.pixelToDocument.inverted()
            var coverage = CIImage(color: .white).cropped(to: stroke.canvas)
            if let clip = stroke.selectionClip {
                guard let selection = clip.coverage.flatMap({ placement.renderer.image($0, mask: true) }) else { return nil }
                let placed = selection.transformed(by: CGAffineTransform(scaleX: clip.rect.width / selection.extent.width,
                                                                         y: clip.rect.height / selection.extent.height)
                    .concatenating(CGAffineTransform(translationX: clip.rect.minX, y: clip.rect.minY)))
                coverage = coverage.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.black,
                                                                                      kCIInputMaskImageKey: placed])
            }
            let shaded = GPUBlend.faded(GPUBlend.masked(shading, by: coverage), Double(fill.opacity))
            return shaded.transformed(by: toGrid)
        }
        // One layer's pixels, placed, through its own mask and at its opacity.
        func own(_ layer: ImageLayer) -> CIImage? {
            let opacity = layer.effectiveOpacity(in: byID)
            // Text being edited, as it will be committed.
            if layer.id == session.textDraft?.layerID {
                guard let shown = textRendering.editedText(layer, shownAt: textShownTransform()) else { return nil }
                guard let image = placement.place(shown.image, transform: shown.transform) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            // Smudge or Liquify in progress: the layer as the stroke has reshaped it so far, across the canvas.
            if let warp = session.warpStroke, warp.layer.id == layer.id, warp.gpu != nil || warp.image != nil {
                let canvas = LayerTransform(origin: .zero, size: document.size)
                let shown: CIImage?
                if let working = warp.gpu?.image {
                    shown = placement.place(live: working, width: warp.width, height: warp.height, transform: canvas)
                } else {
                    shown = warp.image.flatMap { placement.place(transient: $0, transform: canvas) }
                }
                guard var placed = shown else { unsupported = true; return nil }
                if let mask = layer.mask?.clipImage(placement: layer.maskTransform, over: canvas, width: warp.width, height: warp.height, limit: 2048) {
                    guard let placedMask = placement.place(mask, transform: canvas, mask: true) else { unsupported = true; return nil }
                    placed = GPUBlend.masked(placed, by: placedMask)
                }
                return GPUBlend.faded(placed, opacity)
            }
            let stroke = session.brushStroke?.layer.id == layer.id ? session.brushStroke
                : session.gradientEdit?.raster.layer.id == layer.id ? session.gradientEdit?.raster : nil
            if let stroke {
                guard let image = painted(layer, stroke: stroke, opacity: opacity) else { unsupported = true; return nil }
                return image
            }
            // Pixels being moved: the layer with the selection cut out (all of it, duplicating), the lifted pixels over it.
            if let move = session.pixelMove, move.raster.layer.id == layer.id, !move.drawsOnGPU {
                try? move.applyOffset()
                guard let image = painted(layer, stroke: move.raster, opacity: opacity) else { unsupported = true; return nil }
                return image
            }
            if let move = session.pixelMove, move.raster.layer.id == layer.id {
                let stroke = move.raster
                guard let lifted = stroke.lifted, let target = stroke.liftedTarget(offset: move.offset),
                      let rest = move.duplicate ? stroke.original : stroke.holed,
                      let below = placement.place(rest, transform: stroke.transform(for: stroke.sourceRect)),
                      let above = placement.place(lifted.image, transform: stroke.transform(for: target)) else {
                    unsupported = true
                    return nil
                }
                return GPUBlend.faded(above.composited(over: below), opacity)
            }
            guard layer.asset != nil || session.filterEdit?.previewImage(for: layer.id) != nil else { return nil }
            // A distortion in progress, with effects: them, warped into the shape.
            if layer.effects?.visible.isEmpty == false, let edit = session.transformEdit, !edit.mask, edit.corners != nil,
               let effects = session.effectsPreviews.preview(for: layer,
                    mask: layer.mask?.clipImage(placement: session.displayedMaskPlacement(for: layer), over: layer.transform,
                        width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                        height: layer.asset?.image.height ?? Int(layer.size.height.rounded()), limit: 2048),
                    transform: layer.transform, maskPlacement: session.displayedMaskPlacement(for: layer),
                    completion: { [weak self] in self?.needsRedraw() }),
               let warped = session.distortedEffects(for: layer, effects: effects.image, inset: effects.inset) {
                guard let image = placement.place(warped.image, transform: warped.transform) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            // Without: taken into the shape here in perspective, and its mask with it.
            if let target = session.distortShape(for: layer), let image = layer.asset?.image,
               layer.mask.map({ $0.placement == nil && $0.isLinked }) ?? true,
               var warped = placement.warp(image, transform: target.transform, corners: target.corners) {
                if let mask = layer.mask?.enabledImage {
                    guard let shape = placement.warp(mask, transform: target.transform, corners: target.corners, mask: true)
                    else { unsupported = true; return nil }
                    warped = GPUBlend.masked(warped, by: shape)
                }
                return GPUBlend.faded(warped, opacity)
            }
            if let distorted = session.distortPreview(for: layer) {
                guard var image = placement.place(distorted.image, transform: distorted.transform) else { unsupported = true; return nil }
                if let mask = distorted.mask.flatMap({ placement.place($0, transform: distorted.transform, mask: true) }) {
                    image = GPUBlend.masked(image, by: mask)
                }
                return GPUBlend.faded(image, opacity)
            }
            let transform = session.displayedTransform(for: layer)
            // A mask placed apart from its layer is resampled into the layer's grid.
            let mask: CGImage? = {
                guard let owned = layer.mask else { return nil }
                if let distorted = session.maskDistortPreview(for: layer) { return distorted }
                guard let maskPlacement = session.displayedMaskPlacement(for: layer) else { return owned.enabledImage }
                let drawn = max(transform.size.width, transform.size.height) * placement.scale
                let steady = pow(2, ceil(log2(max(64, drawn))))
                return owned.clipImage(placement: maskPlacement, over: transform,
                    width: layer.asset?.image.width ?? Int(transform.size.width.rounded()),
                    height: layer.asset?.image.height ?? Int(transform.size.height.rounded()),
                    limit: session.transformEdit != nil ? min(2048, steady) : steady)
            }()
            // A filter's or an adjustment's preview, shown in place of the layer's pixels.
            let previewed = session.filterEdit?.previewImage(for: layer.id) ?? session.levels?.previewImage(for: layer.id)
                ?? session.hueSaturation?.previewImage(for: layer.id)
            if layer.asset != nil,
               let effects = session.effectsPreviews.preview(for: layer, pixels: previewed, mask: mask, transform: transform,
                    maskPlacement: session.displayedMaskPlacement(for: layer), completion: { [weak self] in
                        self?.needsRedraw()
                    }) {
                let grown = effects.placement ?? LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                guard let image = placement.place(effects.image, transform: grown) else { unsupported = true; return nil }
                return GPUBlend.faded(image, opacity)
            }
            let placed: CIImage?
            if let shaped = session.shapeTransformPreview(for: layer, transform: transform) {
                placed = placement.place(shaped, transform: transform)
            } else if let raster = layer.asset?.raster, previewed == nil {
                placed = placement.place(raster, transform: transform)
            } else if let image = previewed ?? layer.asset?.image {
                placed = placement.place(image, transform: transform)
            } else { return nil }
            guard var image = placed else { unsupported = true; return nil }
            if let mask {
                guard let placedMask = placement.place(mask, transform: transform, mask: true) else { unsupported = true; return nil }
                image = GPUBlend.masked(image, by: placedMask)
            }
            return GPUBlend.faded(image, opacity)
        }
        // An adjustment re-colors what's under it, through its own mask and its folders' masks, at its opacity.
        func adjusted(_ below: CIImage, by layer: ImageLayer, adjustment: LayerAdjustment, folders: Bool) -> CIImage? {
            guard var changed = GPUAdjustment.apply(adjustment, to: below, scale: placement.scale, mapping: placement.mapping)
            else { return nil }
            let mode = session.displayedBlendMode(for: layer)
            if mode != .normal {
                func opaque(_ image: CIImage) -> CIImage {
                    image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                }
                changed = GPUBlend.blend(opaque(changed), over: opaque(below), mode: mode)
                    .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                         kCIInputMaskImageKey: below])
            }
            var coverage: CIImage?
            func multiply(_ mask: CIImage) {
                coverage = coverage.map {
                    $0.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.black,
                                                                          kCIInputMaskImageKey: mask])
                } ?? mask
            }
            if layer.mask?.isEnabled == true, let edit = liveMaskEdit(for: layer.id), let placed = paintedMask(edit) {
                multiply(placed)
            } else if let own = layer.mask?.enabledImage, let placed = placement.place(own, transform: layer.transform, mask: true) {
                multiply(placed)
            }
            if folders {
                var folder = layer.parentID, depth = 0
                while let current = folder, depth < 64 {
                    if let mask = folderMask(current) { multiply(mask) }
                    folder = byID[current]?.parentID
                    depth += 1
                }
            }
            let opacity = layer.effectiveOpacity(in: byID)
            if opacity < 1 {
                multiply(CIImage(color: CIColor(red: opacity, green: opacity, blue: opacity)))
            }
            guard let coverage else { return changed }
            return changed.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: below,
                                                                              kCIInputMaskImageKey: coverage])
        }
        // A layer shown through the coverage of the layer it takes its mask from.
        var visiting = Set<UUID>()
        func live(_ layer: ImageLayer) -> CIImage? {
            guard let image = own(layer) else { return nil }
            guard let sourceID = layer.maskSourceID else { return image }
            guard let source = byID[sourceID], !visiting.contains(sourceID), visiting.count < 256 else { return CIImage.empty() }
            visiting.insert(sourceID)
            defer { visiting.remove(sourceID) }
            guard let coverage = live(source) else { return unsupported ? nil : CIImage.empty() }
            return image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                             kCIInputMaskImageKey: coverage])
        }
        var result = CIImage.empty()
        // A shape being dragged out and new text go where their layers will: just above the active layer, or new text on
        // top when that isn't drawn.
        var drewNewText = false
        func drafts(after id: UUID, over image: CIImage) -> CIImage {
            guard id == session.activeLayerID else { return image }
            var result = image
            if let shape = session.shapeDraftImage(placement: placement) { result = shape.composited(over: result) }
            if session.textDraft?.layerID == nil, let text = textRendering.text(shownAt: textShownTransform()),
               let placed = placement.place(text.image, transform: text.transform) {
                result = placed.composited(over: result)
                drewNewText = true
            }
            return result
        }
        for id in ids where !stacked.contains(id) {
            guard let layer = byID[id] else { continue }
            let mode = session.displayedBlendMode(for: layer)
            if let adjustment = layer.adjustment {
                guard layer.maskSourceID == nil else { continue }
                guard let changed = adjusted(result, by: layer, adjustment: adjustment, folders: true) else { return nil }
                result = changed
                continue
            }
            if let children = stacks[id] {
                // The base's pixels, opaque, take the layers clipped to it; the stack then keeps the base's coverage.
                guard let base = own(layer) else {
                    if unsupported { return nil }
                    continue
                }
                var group = base.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                group = drafts(after: id, over: group)
                for childID in children {
                    guard let child = byID[childID] else { continue }
                    if let adjustment = child.adjustment {
                        guard let changed = adjusted(group, by: child, adjustment: adjustment, folders: false) else { return nil }
                        group = changed
                    } else if let image = own(child) {
                        group = GPUBlend.blend(image, over: group, mode: session.displayedBlendMode(for: child))
                    } else if unsupported { return nil }
                    group = drafts(after: childID, over: group)
                }
                let stack = group.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                                       kCIInputMaskImageKey: base])
                result = GPUBlend.blend(clippedByFolders(id, stack), over: result, mode: mode)
                continue
            }
            // A layer masked by another's coverage, outside a clipping stack.
            if let image = live(layer) {
                result = GPUBlend.blend(clippedByFolders(id, image), over: result, mode: mode)
            } else if unsupported { return nil }
            result = drafts(after: id, over: result)
        }
        if !drewNewText, session.textDraft?.layerID == nil, let text = textRendering.text(shownAt: textShownTransform()),
           let placed = placement.place(text.image, transform: text.transform) {
            result = placed.composited(over: result)
        }
        return result
    }

    private func strokeSurface(layer: ImageLayer, stroke: BrushStroke, mask: CGImage?) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid else { return nil }
        let grid = CGSize(width: stroke.width, height: stroke.height)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: stroke.sourceRect)
        }
        guard let surface = strokeSurface else { return nil }
        if stroke.isMask {
            let old = stroke.layer.mask?.asset.image, patches = stroke.patches, sourceRect = stroke.sourceRect, background = stroke.maskBackground
            surface.update(base: stroke.layer.asset?.image, patches: [], mask: nil, maskStroke: .init(patches: patches, toGrid: .identity) { region in
                guard let coverage = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true) else { return nil }
                coverage.translateBy(x: -region.minX, y: -region.minY)
                coverage.setFillColor(gray: background, alpha: 1)
                coverage.fill(region)
                if let old { BrushRaster.draw(old, in: sourceRect, mask: true, context: coverage) }
                for patch in patches where patch.rect.intersects(region) {
                    BrushRaster.draw(patch.image, in: patch.rect, mask: true, context: coverage)
                }
                return coverage.makeImage()
            })
        } else {
            surface.update(base: stroke.layer.asset?.image, patches: stroke.patches, mask: mask)
        }
        return surface
    }

    private func placedMaskSurface(layer: ImageLayer, stroke: BrushStroke, placement: LayerTransform, preview: CGImage) -> LayerEffectsSurface? {
        guard let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid, let base = stroke.layer.asset?.image else { return nil }
        let grid = CGSize(width: base.width, height: base.height)
        let full = CGRect(origin: .zero, size: grid)
        if strokeSurface?.matches(layerID: layer.id, effects: effects, grid: grid, sourceRect: full) != true {
            strokeSurface = LayerEffectsSurface(layerID: layer.id, effects: effects, grid: grid, sourceRect: full)
        }
        guard let surface = strokeSurface else { return nil }
        let toGrid = BrushRaster.pixelToDocument(stroke.paintTransform, width: stroke.width, height: stroke.height)
            .concatenating(BrushRaster.pixelToDocument(stroke.layer.transform, width: base.width, height: base.height).inverted())
        surface.update(base: base, patches: [], mask: nil, maskStroke: .init(patches: stroke.patches, toGrid: toGrid) { region in
            guard let coverage = try? BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true) else { return nil }
            coverage.translateBy(x: -region.minX, y: -region.minY)
            coverage.interpolationQuality = .medium
            coverage.saveGState()
            coverage.translateBy(x: 0, y: full.maxY)
            coverage.scaleBy(x: 1, y: -1)
            coverage.draw(preview, in: full)
            coverage.restoreGState()
            return coverage.makeImage()
        })
        return surface
    }
}
