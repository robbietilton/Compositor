import CoreGraphics
import Foundation

/// Draws a layer held as an unchanged image plus replacement tiles — a painted layer's raster snapshot, or a
/// brush stroke in progress — so it looks the same as those pixels drawn as one image by `LayerRenderer`.
///
/// Drawing each tile on its own resamples it without its neighbours (seams) and can't use the sharp halvings,
/// and the live stroke used to switch the whole layer to Nearest, so pixels shifted when painting started and
/// again when it ended. Instead the tiled areas are rebuilt as pieces: squares of the layer grid, aligned to
/// every halving, recomposed at full resolution with a margin of surrounding pixels, reduced with the same
/// halvings as the image, and drawn only inside the square. The margin covers everything the halvings and Core
/// Graphics's last resample can reach, so a piece's pixels match the whole image's; the unchanged image fills
/// the rest. Clips are hard-edged so the parts meet without gaps or overlap.
nonisolated enum TiledLayerRenderer {
    nonisolated struct Piece: @unchecked Sendable {
        /// Grid pixels this piece draws.
        let interior: CGRect
        /// Grid pixels its image holds: the interior and a margin.
        let region: CGRect
        let image: CGImage
        func offsetBy(_ offset: CGPoint) -> Piece {
            Piece(interior: interior.offsetBy(dx: offset.x, dy: offset.y), region: region.offsetBy(dx: offset.x, dy: offset.y), image: image)
        }
    }

    /// Grid pixels beyond a change that its reduced, resampled pixels can reach, with room to spare.
    static func support(level: Int) -> CGFloat { level == 0 ? 8 : CGFloat(16 << level) }
    /// Piece squares: committed snapshots use large ones (fewer to build, once), live strokes small ones (little
    /// to rebuild per mouse move). Both are whole multiples of every halving used.
    static let committedCell: CGFloat = 1024
    static let strokeCell: CGFloat = 256

    /// How one layer's grid maps into the (already transformed) context.
    struct Frame {
        let bounds: CGRect
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        let level: Int
        let device: CGFloat
        let sampling: LayerSampling
        /// Grid pixels the context's clip can show.
        let visible: CGRect
        func mapped(_ rect: CGRect) -> CGRect {
            CGRect(x: bounds.minX + rect.minX / pixelWidth * bounds.width,
                   y: bounds.maxY - rect.maxY / pixelHeight * bounds.height,
                   width: rect.width / pixelWidth * bounds.width,
                   height: rect.height / pixelHeight * bounds.height)
        }
    }

    // MARK: Drawing

    /// A committed raster snapshot (a painted layer).
    static func drawRaster(_ raster: RasterSnapshot, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                           opacity: Double, blendMode: LayerBlendMode, mask: CGImage?, in context: CGContext) {
        withFrame(pixelWidth: raster.width, pixelHeight: raster.height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            if let mask { clipToMask(mask, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height), frame: frame, context: context) }
            drawCommitted(raster, at: .zero, holes: [], frame: frame, in: context)
        }
    }

    /// A tiled edit in progress (`patches`, in a `width` × `height` grid) over the layer's previous pixels —
    /// `image` or `raster`, sitting at `sourceRect` — drawn as the finished layer will look.
    static func drawStroke(width: Int, height: Int, sourceRect: CGRect, patches: [BrushPatch], image: CGImage?, raster: RasterSnapshot?,
                           transform: LayerTransform, center: CGPoint, scale: CGFloat, opacity: Double, blendMode: LayerBlendMode,
                           mask: CGImage?, in context: CGContext) {
        withFrame(pixelWidth: width, pixelHeight: height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            let origin = CGPoint(x: sourceRect.minX + (raster?.alignment.x ?? 0), y: sourceRect.minY + (raster?.alignment.y ?? 0))
            let squares = interiors(near: patches.map(\.rect), margin: support(level: frame.level), size: strokeCell,
                                    step: CGFloat(1 << frame.level), origin: origin, visible: frame.visible)
            let painted = patches.reduce(CGRect(x: 0, y: 0, width: width, height: height)) { $0.union($1.rect) }
            let pieces = squares.compactMap { square in
                piece(interior: square, level: frame.level, origin: origin, bounds: painted) { context, region in
                    if let raster {
                        raster.draw(in: CGRect(origin: sourceRect.origin, size: CGSize(width: raster.width, height: raster.height)), context: context)
                    } else if let image {
                        drawCropped(image, at: sourceRect, within: region, in: context)
                    }
                    for patch in patches where patch.rect.intersects(region) {
                        BrushRaster.draw(patch.image, in: patch.rect, mask: false, context: context)
                    }
                }
            }
            context.saveGState()
            if let mask { clipToMask(mask, in: sourceRect, frame: frame, context: context) }
            drawReplacing(pieces.map(\.interior), frame: frame, in: context, unchanged: {
                if let raster {
                    drawCommitted(raster, at: sourceRect.origin, holes: [], frame: frame, in: context)
                } else if let image {
                    drawBase(image, at: sourceRect, holes: [], frame: frame, in: context)
                }
            }, replace: { draw(pieces[$0], holes: [], frame: frame, in: context) })
            context.restoreGState()
            // Paint beyond the layer's old bounds is revealed, not masked.
            if mask != nil {
                for piece in pieces where !sourceRect.contains(piece.interior) {
                    draw(piece, holes: [sourceRect], frame: frame, in: context)
                }
            }
        }
    }

    /// Painting a layer's mask (`patches` of coverage in a `width` × `height` grid, over `oldMask` at `sourceRect`):
    /// the layer's pixels — `image` or `raster`, also at `sourceRect` — drawn through the mask as it will be once
    /// committed: pieces of the new mask where the stroke's tiles can show, the old mask elsewhere.
    static func drawMaskStroke(width: Int, height: Int, sourceRect: CGRect, patches: [BrushPatch], oldMask: ImportedImage?,
                               image: CGImage?, raster: RasterSnapshot?, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                               opacity: Double, blendMode: LayerBlendMode, in context: CGContext) {
        withFrame(pixelWidth: width, pixelHeight: height, transform: transform, center: center, scale: scale,
                  opacity: opacity, blendMode: blendMode, in: context) { frame in
            // Pieces are halved on the mask image's own grid and levels, the way the old mask is.
            let level = frame.sampling == .nearest ? 0
                : DownsampleCache.level(for: frame.mapped(sourceRect).width * frame.device / max(1, sourceRect.width))
            let found = interiors(near: patches.map(\.rect), margin: support(level: level), size: strokeCell,
                                  step: CGFloat(1 << level), origin: sourceRect.origin, visible: frame.visible)
            let pieces = found.compactMap { interior in
                piece(interior: interior, level: level, origin: sourceRect.origin, bounds: sourceRect, mask: true) { context, region in
                    // Beyond the old mask an edit reveals, as mask edits do.
                    context.setFillColor(gray: 1, alpha: 1)
                    context.fill(region)
                    if let old = oldMask?.raster {
                        old.draw(in: sourceRect, context: context)
                    } else if let old = oldMask?.image {
                        drawCropped(old, at: sourceRect, within: region, mask: true, in: context)
                    }
                    for patch in patches where patch.rect.intersects(region) {
                        BrushRaster.draw(patch.image, in: patch.rect, mask: true, context: context)
                    }
                }
            }
            func drawLayer() {
                if let raster { drawCommitted(raster, at: sourceRect.origin, holes: [], frame: frame, in: context) }
                else if let image { drawBase(image, at: sourceRect, holes: [], frame: frame, in: context) }
            }
            drawReplacing(pieces.map(\.interior), frame: frame, in: context, unchanged: {
                context.saveGState()
                if let old = oldMask?.image { clipToMask(old, in: sourceRect, frame: frame, context: context) }
                drawLayer()
                context.restoreGState()
            }, replace: { index in
                context.saveGState()
                clip(to: pieces[index].interior, excluding: [], frame: frame, in: context)
                context.clip(to: frame.mapped(pieces[index].region), mask: pieces[index].image)
                drawLayer()
                context.restoreGState()
            })
        }
    }

    /// Draws `unchanged` everywhere but `interiors`, and `replace(i)` inside interior `i`. Core Graphics's hard clips
    /// cover every pixel they touch, so two neighbouring clips both draw the pixels their shared edge splits —
    /// hidden by opaque pixels, but a line wherever the layer or its mask is translucent. Clips on device-pixel
    /// edges do split exactly, so the pieces' device-aligned bounds are assembled apart, in a transparency layer
    /// where each interior is cleared before its replacement draws, and composited once.
    private static func drawReplacing(_ interiors: [CGRect], frame: Frame, in context: CGContext,
                                      unchanged: () -> Void, replace: (Int) -> Void) {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let visible = context.boundingBoxOfClipPath
        guard let first = interiors.first else { unchanged(); return }
        let union = interiors.dropFirst().reduce(first) { $0.union($1) }
        let device = frame.mapped(union).applying(toDevice)
            .intersection(visible.applying(toDevice).insetBy(dx: -2, dy: -2)).integral
        guard !device.isNull, !device.isEmpty else { unchanged(); return }
        let toUser = toDevice.inverted()

        context.saveGState()
        context.setShouldAntialias(false)
        let outline = CGPath(rect: visible.insetBy(dx: -64, dy: -64), transform: nil)
        let replacement = CGPath(rect: device.insetBy(dx: -0.001, dy: -0.001), transform: [toUser])
        context.addPath(LegacyCGPath.subtracting(outline, replacement, in: outline.boundingBoxOfPath))
        context.clip()
        unchanged()
        context.restoreGState()

        context.saveGState()
        context.setShouldAntialias(false)
        context.addPath(CGPath(rect: device.insetBy(dx: 0.001, dy: 0.001), transform: [toUser]))
        context.clip()
        // Composited with the layer's opacity and blend mode; drawn inside at full strength, normally.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.setBlendMode(.normal)
        unchanged()
        for index in interiors.indices {
            context.saveGState()
            clip(to: interiors[index], excluding: [], frame: frame, in: context)
            context.setBlendMode(.clear)
            context.fill(frame.mapped(interiors[index]))
            context.restoreGState()
            replace(index)
        }
        context.restoreGState()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func withFrame(pixelWidth: Int, pixelHeight: Int, transform: LayerTransform, center: CGPoint, scale: CGFloat,
                                  opacity: Double, blendMode: LayerBlendMode, in context: CGContext, _ body: (Frame) -> Void) {
        let width = transform.size.width * scale, height = transform.size.height * scale
        guard width > 0, height > 0, pixelWidth > 0, pixelHeight > 0 else { return }
        let device = LayerRenderer.deviceScale(of: context)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: width * device / CGFloat(pixelWidth))
        context.saveGState()
        context.setAlpha(opacity)
        context.setBlendMode(blendMode.cgMode)
        context.interpolationQuality = LayerRenderer.interpolation(transform.sampling,
            finalFactor: width * device / CGFloat(pixelWidth) * CGFloat(1 << level))
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? 1 : -1)
        let bounds = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let clip = context.boundingBoxOfClipPath
        let sx = CGFloat(pixelWidth) / width, sy = CGFloat(pixelHeight) / height
        let visible = CGRect(x: (clip.minX - bounds.minX) * sx, y: (bounds.maxY - clip.maxY) * sy,
                             width: clip.width * sx, height: clip.height * sy)
        body(Frame(bounds: bounds, pixelWidth: CGFloat(pixelWidth), pixelHeight: CGFloat(pixelHeight), level: level,
                   device: device, sampling: transform.sampling, visible: visible))
        context.restoreGState()
    }

    /// A committed raster placed at `offset` in the frame's grid, leaving `holes` for pieces drawn over it.
    private static func drawCommitted(_ raster: RasterSnapshot, at offset: CGPoint, holes: [CGRect], frame: Frame, in context: CGContext) {
        let pieces = TiledPieceCache.shared.pieces(for: raster, level: frame.level).map { $0.offsetBy(offset) }
        if let base = raster.base {
            drawBase(base, at: raster.baseRect.offsetBy(dx: offset.x, dy: offset.y), holes: pieces.map(\.interior) + holes,
                     frame: frame, in: context)
        }
        let visible = frame.visible.insetBy(dx: -2, dy: -2)
        for piece in pieces where piece.interior.intersects(visible) {
            draw(piece, holes: holes, frame: frame, in: context)
        }
    }

    /// The unchanged image (placed at `rect`) reduced by the frame's halvings, everywhere but `holes`.
    private static func drawBase(_ image: CGImage, at rect: CGRect, holes: [CGRect], frame: Frame, in context: CGContext) {
        let reduced = DownsampleCache.shared.image(image, level: frame.level)
        let step = CGFloat(1 << reduced.level)
        let covered = CGRect(x: rect.minX, y: rect.minY,
                             width: CGFloat(reduced.image.width) * step * rect.width / CGFloat(max(1, image.width)),
                             height: CGFloat(reduced.image.height) * step * rect.height / CGFloat(max(1, image.height)))
        context.saveGState()
        // The image's own edges antialias as usual; only the pieces' squares are cut out.
        clip(to: covered.insetBy(dx: -step - 8, dy: -step - 8), excluding: holes, frame: frame, in: context)
        context.setShouldAntialias(frame.sampling != .nearest)
        context.draw(reduced.image, in: frame.mapped(covered))
        context.restoreGState()
    }

    private static func draw(_ piece: Piece, holes: [CGRect], frame: Frame, in context: CGContext) {
        context.saveGState()
        clip(to: piece.interior, excluding: holes, frame: frame, in: context)
        context.setShouldAntialias(frame.sampling != .nearest)
        context.draw(piece.image, in: frame.mapped(piece.region))
        context.restoreGState()
    }

    /// Clips to `area` less `holes` (grid pixels) with hard edges, so neighbouring draws meet exactly.
    private static func clip(to area: CGRect, excluding holes: [CGRect], frame: Frame, in context: CGContext) {
        context.setShouldAntialias(false)
        let outline = CGPath(rect: snapped(frame.mapped(area), in: context), transform: nil)
        let cut = CGMutablePath()
        for hole in holes where hole.intersects(area) { cut.addRect(snapped(frame.mapped(hole), in: context)) }
        context.addPath(cut.isEmpty ? outline : LegacyCGPath.subtracting(outline, cut, in: outline.boundingBoxOfPath))
        context.clip()
    }

    /// A clip edge on a fraction of a screen pixel leaves that pixel to be rounded one way here and the other way in
    /// the neighbouring piece, which shows as a hairline across translucent pixels. Rounding each edge to whole
    /// screen pixels first makes two pieces that share an edge round it the same way and meet exactly. Skipped for a
    /// rotated layer, whose pieces don't lie along the screen's pixels at all.
    private static func snapped(_ rect: CGRect, in context: CGContext) -> CGRect {
        let toDevice = context.userSpaceToDeviceSpaceTransform
        guard abs(toDevice.b) < 1e-9, abs(toDevice.c) < 1e-9, toDevice.a != 0, toDevice.d != 0 else { return rect }
        let device = rect.applying(toDevice)
        let snapped = CGRect(x: device.minX.rounded(), y: device.minY.rounded(),
                             width: max(0, device.maxX.rounded() - device.minX.rounded()),
                             height: max(0, device.maxY.rounded() - device.minY.rounded()))
        return snapped.applying(toDevice.inverted())
    }

    private static func clipToMask(_ mask: CGImage, in rect: CGRect, frame: Frame, context: CGContext) {
        let target = frame.mapped(rect)
        let reduced = LayerRenderer.reduced(mask, width: target.width, device: frame.device, sampling: frame.sampling)
        context.clip(to: LayerRenderer.coverage(of: reduced, in: target), mask: reduced.image)
    }

    // MARK: Pieces

    /// A piece drawing `interior`: `compose` draws full-resolution grid pixels (into a context whose origin is
    /// the grid's) over the interior grown by the support, which is then reduced to `level`.
    /// `bounds` (grid pixels) is everything that holds pixels — the layer's grid, plus anything painted past it.
    /// The margin is kept inside it: past that edge there is nothing to compose, and resampling a piece whose
    /// margin is empty pulls that emptiness into the layer's edge, which the whole image's own draw never does.
    static func piece(interior: CGRect, level: Int, origin: CGPoint, bounds: CGRect? = nil, mask: Bool = false,
                      compose: (CGContext, CGRect) -> Void) -> Piece? {
        let margin = support(level: level)
        var region = aligned(interior.insetBy(dx: -margin, dy: -margin), step: CGFloat(1 << level), origin: origin)
        if let bounds {
            let limit = aligned(bounds, step: CGFloat(1 << level), origin: origin)
            region = region.intersection(limit)
            guard !region.isNull, !region.isEmpty else { return nil }
        }
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, width * height <= 64_000_000,
              let context = try? BrushRaster.context(width: width, height: height, mask: mask) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.translateBy(x: -region.minX, y: -region.minY)
        compose(context, region)
        context.restoreGState()
        guard var image = context.makeImage() else { return nil }
        for _ in 0..<level {
            guard let half = DownsampleCache.halve(image) else { return nil }
            image = half
        }
        let kept = bounds == nil ? interior : interior.intersection(region)
        guard !kept.isNull, !kept.isEmpty else { return nil }
        return Piece(interior: kept, region: region, image: image)
    }

    /// Piece interiors: in each `size` square (from `origin`), the part within `margin` of any of `rects`, grown
    /// to the `step` grid. Pieces stay disjoint and go only where changes can show — clear of the layer's own
    /// edges unless something was painted near them. Limited to what `visible` shows.
    static func interiors(near rects: [CGRect], margin: CGFloat, size: CGFloat, step: CGFloat, origin: CGPoint, visible: CGRect?) -> [CGRect] {
        var parts: [SIMD2<Int>: CGRect] = [:]
        for rect in rects {
            let grown = rect.insetBy(dx: -margin, dy: -margin)
            if let visible, !grown.intersects(visible) { continue }
            let x0 = Int(floor((grown.minX - origin.x) / size)), x1 = Int(ceil((grown.maxX - origin.x) / size))
            let y0 = Int(floor((grown.minY - origin.y) / size)), y1 = Int(ceil((grown.maxY - origin.y) / size))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let square = CGRect(x: origin.x + CGFloat(x) * size, y: origin.y + CGFloat(y) * size, width: size, height: size)
                    let part = grown.intersection(square)
                    guard !part.isNull, !part.isEmpty else { continue }
                    let key = SIMD2(x, y)
                    parts[key] = parts[key].map { $0.union(part) } ?? part
                }
            }
        }
        // Squares sit on the step grid, so growing a part to it never leaves its square.
        return parts.values.map { aligned($0, step: step, origin: origin) }
            .filter { interior in visible.map { interior.intersects($0) } ?? true }
    }

    /// `rect` grown outward to whole multiples of `step` measured from `origin`.
    static func aligned(_ rect: CGRect, step: CGFloat, origin: CGPoint) -> CGRect {
        let minX = origin.x + floor((rect.minX - origin.x) / step) * step
        let minY = origin.y + floor((rect.minY - origin.y) / step) * step
        let maxX = origin.x + ceil((rect.maxX - origin.x) / step) * step
        let maxY = origin.y + ceil((rect.maxY - origin.y) / step) * step
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The part of `image` (placed at `rect`) inside `region`: cropped when it is 1:1 with the grid, otherwise
    /// (a solid 1 × 1 mask, say) drawn stretched over `rect`.
    private static func drawCropped(_ image: CGImage, at rect: CGRect, within region: CGRect, mask: Bool = false, in context: CGContext) {
        guard CGFloat(image.width) == rect.width, CGFloat(image.height) == rect.height else {
            BrushRaster.draw(image, in: rect, mask: mask, context: context)
            return
        }
        let local = region.offsetBy(dx: -rect.minX, dy: -rect.minY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !local.isNull, !local.isEmpty, let crop = image.cropping(to: local) else { return }
        BrushRaster.draw(crop, in: local.offsetBy(dx: rect.minX, dy: rect.minY), mask: mask, context: context)
    }
}

/// Committed rasters' pieces, built once per snapshot and level (snapshots never change); the least recently
/// used are dropped beyond a pixel budget.
nonisolated final class TiledPieceCache: @unchecked Sendable {
    static let shared = TiledPieceCache()
    static let pixelBudget = 150_000_000
    private struct Key: Hashable {
        let raster: ObjectIdentifier
        let level: Int
    }
    private struct Entry {
        let raster: RasterSnapshot
        let pieces: [TiledLayerRenderer.Piece]
        var lastUse: UInt64
        let pixels: Int
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private let lock = NSLock()

    func pieces(for raster: RasterSnapshot, level: Int) -> [TiledLayerRenderer.Piece] {
        let key = Key(raster: ObjectIdentifier(raster), level: level)
        lock.lock()
        clock += 1
        if let entry = entries[key], entry.raster === raster {
            entries[key]?.lastUse = clock
            lock.unlock()
            return entry.pieces
        }
        lock.unlock()
        let origin = raster.alignment
        let full = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        let squares = TiledLayerRenderer.interiors(near: raster.patches.map(\.rect), margin: TiledLayerRenderer.support(level: level),
                                                   size: TiledLayerRenderer.committedCell, step: CGFloat(1 << level), origin: origin, visible: nil)
        let pieces = squares.compactMap { square in
            TiledLayerRenderer.piece(interior: square, level: level, origin: origin, bounds: full) { context, _ in raster.draw(in: full, context: context) }
        }
        let pixels = pieces.reduce(0) { $0 + $1.image.width * $1.image.height }
        lock.lock()
        entries[key] = Entry(raster: raster, pieces: pieces, lastUse: clock, pixels: pixels)
        var total = entries.values.reduce(0) { $0 + $1.pixels }
        while total > Self.pixelBudget,
              let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            total -= oldest.value.pixels
            entries.removeValue(forKey: oldest.key)
        }
        lock.unlock()
        return pieces
    }
}
