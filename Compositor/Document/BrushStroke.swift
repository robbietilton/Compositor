import AppKit

nonisolated enum SpotHealingMode: String, CaseIterable, Sendable, Hashable {
    case contentAware = "Content-Aware"
    case createTexture = "Create Texture"
    case proximityMatch = "Proximity Match"
}

nonisolated struct BrushSettings: Sendable {
    var diameter: CGFloat = 40
    var hardness: CGFloat = 1
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    /// Caps the whole stroke, as in Photoshop: overlapping dabs never exceed it.
    var opacity: CGFloat = 1
    /// 0–100. The brush trails the pointer on a string of this length, so a shaky hand
    /// draws a smooth line; 0 follows the pointer exactly.
    var smoothing: CGFloat = 0
    /// Spot-healing uses nearby source pixels instead of the foreground color.
    /// Erase: the stroke clears the layer's pixels instead of painting color on them.
    var erasing = false
    var healing = false
    var healingMode: SpotHealingMode = .contentAware
}

nonisolated struct BrushPatch: @unchecked Sendable {
    let rect: CGRect
    let image: CGImage
}

/// Shared top-left raster drawing, including coverage without color conversion.
nonisolated enum BrushRaster {
    static func context(width: Int, height: Int, mask: Bool) throws -> CGContext {
        guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * (mask ? 1 : 4),
            space: mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: mask ? CGImageAlphaInfo.none.rawValue : (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)) else { throw ExportError.render }
        result.translateBy(x: 0, y: CGFloat(height))
        result.scaleBy(x: 1, y: -1)
        return result
    }
    static func draw(_ image: CGImage, in rect: CGRect, mask: Bool, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: rect.size)
        if mask {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(bounds)
            context.clip(to: bounds, mask: image)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
        } else {
            context.setBlendMode(.copy)
            context.draw(image, in: bounds)
        }
        context.restoreGState()
    }
    /// Paints a solid color through grayscale coverage at a uniform alpha.
    static func fill(_ color: CGColor, coverage: CGImage, in rect: CGRect, alpha: CGFloat, context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let bounds = CGRect(origin: .zero, size: rect.size)
        context.clip(to: bounds, mask: coverage)
        context.setAlpha(alpha)
        context.setFillColor(color)
        context.fill(bounds)
        context.restoreGState()
    }
    /// Soft-brush falloff across the region between the hardness radius and the rim:
    /// a normalized Gaussian that fades across the whole radius and reaches zero at the rim.
    static func falloff(_ u: CGFloat) -> CGFloat {
        let k: CGFloat = 2.5
        return max(0, (exp(-k * u * u) - exp(-k)) / (1 - exp(-k)))
    }
    static func pixelToDocument(_ transform: LayerTransform, width: Int, height: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: transform.center.x, y: transform.center.y)
            .rotated(by: transform.radians)
            .scaledBy(x: transform.size.width / CGFloat(width) * (transform.flipX ? -1 : 1),
                      y: transform.size.height / CGFloat(height) * (transform.flipY ? -1 : 1))
            .translatedBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
    }
}

/// Only touched 256px tiles allocate writable pixels. Snapshots copy at most
/// those tiles, never the entire layer on a mouse-move event.
final class BrushStroke {
    let layer: ImageLayer
    let isMask: Bool
    let width: Int
    let height: Int
    let settings: BrushSettings
    let canvas: CGRect
    let pixelToDocument: CGAffineTransform
    let sourceRect: CGRect
    let paintTransform: LayerTransform
    private let source: CGImage?
    private let paintColor: CGColor
    private let falloff: CGGradient?
    /// The brush tip, rendered once and stamped for every dab. Only worth it up to
    /// `stampLimit`: past that, blitting the big tip costs more than drawing the falloff.
    private let stamp: CGImage?
    static let stampLimit: CGFloat = 160
    /// The tip again, sized in layer pixels so dabs land 1:1 on the grid with nothing for
    /// Core Graphics to resample — which is most of what a wide dab used to cost. Only for
    /// layers square on the grid and evenly scaled; a rotated or squashed one falls back to
    /// drawing `stamp` through the tile transform.
    private let gridTip: CGImage?
    /// Past this width the tip is left to the fallback rather than held in memory.
    private static let gridTipLimit: CGFloat = 3000
    var pixelLimit = 100_000_000
    /// Limits every edit to the document selection; nil when nothing is selected.
    var selectionClip: SelectionClip?
    /// Clone Stamp: a document-size image to copy from, and the offset from each painted point to its source.
    var clone: (image: CGImage, offset: CGSize)?
    /// A Blur stroke: `clone` holds the layer blurred, painted in place through the tip.
    var isBlur = false
    /// The clone sample replaces what's under the tip rather than drawing over it, so it can also clear pixels.
    var replacesWithClone = false
    /// The undo name, when the stroke's kind doesn't say it.
    var editName: String?
    private var allocatedBounds: CGRect?
    private var previous: CGPoint?
    private var samples: [CGPoint] = []
    /// Coverage under the provisional tail; nil where the tile had no coverage yet.
    private var tailBackup: [Int: CGImage?] = [:]
    private var distanceToNext: CGFloat = 0
    private(set) var dirtyDocumentRect: CGRect?
    private struct Tile { let rect: CGRect; let context: CGContext; var image: CGImage?; let base: CGImage? }
    private var tiles: [Int: Tile] = [:]
    private let gpu: MetalBrushCoverage?
    private var gpuTiles: [Int: MetalBrushCoverage.Tile] = [:]
    private var gpuTailKeys = Set<Int>()
    /// Per-tile grayscale coverage. Soft tips accumulate paint within the stroke;
    /// hard tips keep their antialiased silhouette. Each tile is recomposed as original
    /// + color × coverage × opacity, preserving the stroke-wide opacity cap.
    private var coverage: [Int: CGContext] = [:]
    /// Tile edge in layer pixels. Wider tiles were measured to be no faster for wide
    /// brushes and slower for narrow ones.
    static let tileSize = 256
    /// The part of each tile the stroke touched since the last publish, in tile-local pixels.
    private var dirtyTiles: [Int: CGRect] = [:]
    var patches: [BrushPatch] { tiles.values.compactMap { tile in tile.image.map { BrushPatch(rect: tile.rect, image: $0) } } }

    init(layer: ImageLayer, mask: Bool, settings: BrushSettings, canvas: CGSize, useGPU: Bool = true) throws {
        gpu = useGPU ? MetalBrushCoverage.shared : nil
        self.layer = layer
        isMask = mask
        self.settings = settings
        self.canvas = CGRect(origin: .zero, size: canvas)
        // A mask on its own placement is painted in its own pixel grid; otherwise the grid is the layer's.
        let placedMask = mask ? layer.mask.flatMap { mask in mask.placement.map { (mask.asset.image, $0) } } : nil
        let base = placedMask?.1 ?? layer.transform
        let originalWidth = placedMask?.0.width ?? layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let originalHeight = placedMask?.0.height ?? layer.asset?.image.height ?? Int(layer.size.height.rounded())
        let originalMapping = BrushRaster.pixelToDocument(base, width: originalWidth, height: originalHeight)
        let originalBounds = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        let extent = mask ? originalBounds : originalBounds.union(self.canvas.applying(originalMapping.inverted()).integral)
        width = Int(extent.width)
        height = Int(extent.height)
        sourceRect = originalBounds.offsetBy(dx: -extent.minX, dy: -extent.minY)
        pixelToDocument = originalMapping.translatedBy(x: extent.minX, y: extent.minY)
        var expanded = base
        expanded.size = CGSize(width: CGFloat(width) * base.size.width / CGFloat(originalWidth),
                               height: CGFloat(height) * base.size.height / CGFloat(originalHeight))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(originalMapping)
        expanded.origin = CGPoint(x: center.x - expanded.size.width / 2, y: center.y - expanded.size.height / 2)
        paintTransform = expanded
        guard (1...1_000_000_000).contains(width), (1...1_000_000_000).contains(height),
              (1...30_000).contains(originalWidth), (1...30_000).contains(originalHeight),
              settings.diameter.isFinite, (1...2000).contains(settings.diameter),
              settings.hardness.isFinite, (0...1).contains(settings.hardness),
              settings.opacity.isFinite, (0.01...1).contains(settings.opacity) else { throw ProjectError.tooLarge }
        let space = mask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let components: [CGFloat] = mask ? [settings.red, 1] : [settings.red, settings.green, settings.blue, 1]
        paintColor = CGColor(colorSpace: space, components: components)!
        let steps = 24
        let locations = (0...steps).map { CGFloat($0) / CGFloat(steps) }
        let levels: [CGFloat] = locations.flatMap { [BrushRaster.falloff($0), CGFloat(1)] }
        falloff = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: levels, locations: locations, count: locations.count)
        source = mask ? layer.mask?.asset.image : layer.asset?.image
        let scaleX = hypot(pixelToDocument.a, pixelToDocument.b)
        let scaleY = hypot(pixelToDocument.c, pixelToDocument.d)
        let square = abs(pixelToDocument.b) < 1e-9 && abs(pixelToDocument.c) < 1e-9
            && scaleX > 1e-9 && abs(scaleX - scaleY) < 1e-9
        let gridDiameter = settings.diameter / scaleX
        gridTip = gpu == nil && square && gridDiameter >= 1 && gridDiameter <= Self.gridTipLimit
            ? try Self.tip(diameter: gridDiameter, hardness: settings.hardness, falloff: falloff) : nil
        stamp = gpu == nil && gridTip == nil && settings.diameter <= Self.stampLimit
            ? try Self.tip(diameter: settings.diameter, hardness: settings.hardness, falloff: falloff) : nil
    }

    /// The tip as grayscale coverage: white at full strength, fading to black at the rim.
    private static func tip(diameter: CGFloat, hardness: CGFloat, falloff: CGGradient?) throws -> CGImage {
        let size = max(1, Int(diameter.rounded(.up)))
        let context = try BrushRaster.context(width: size, height: size, mask: true)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(bounds)
        context.setFillColor(gray: 1, alpha: 1)
        if hardness >= 1 {
            context.fillEllipse(in: bounds)
        } else if let falloff {
            let radius = CGFloat(size) / 2
            let center = CGPoint(x: radius, y: radius)
            context.drawRadialGradient(falloff, startCenter: center, startRadius: radius * hardness,
                                       endCenter: center, endRadius: radius, options: [.drawsBeforeStartLocation])
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// Mouse samples arrive sparsely, so dabs follow a smooth curve through them rather
    /// than straight chords. A curve piece needs the sample after it, so the newest piece
    /// is first drawn as a provisional straight tail (the stroke never trails the cursor),
    /// then erased and replaced by the curve when the next sample arrives or on `flush()`.
    func append(_ point: CGPoint) throws {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000 else { return }
        guard samples.last != point else { return }
        if gpu != nil { try appendContinuous(point); return }
        var changed = removeTail()
        samples.append(point)
        if samples.count > 4 { samples.removeFirst() }
        let count = samples.count
        if count == 1 {
            try walk(to: point, changed: &changed)
        } else if count >= 3 {
            try curve(from: samples[count - 3], to: samples[count - 2],
                      before: samples[max(0, count - 4)], after: samples[count - 1], changed: &changed)
        }
        if count >= 2 { try drawTail(from: samples[count - 2], to: point, changed: &changed) }
        try publish(changed)
    }

    /// Replaces the provisional tail with the stroke's final curve piece. Safe to repeat.
    func flush() throws {
        if gpu != nil { try flushContinuous(); return }
        var changed = removeTail()
        let count = samples.count
        if count >= 2 {
            try curve(from: samples[count - 2], to: samples[count - 1],
                      before: samples[max(0, count - 3)], after: samples[count - 1], changed: &changed)
            samples = [samples[count - 1]]
        }
        try publish(changed)
    }

    private func appendContinuous(_ point: CGPoint) throws {
        samples.append(point)
        if samples.count > 4 { samples.removeFirst() }
        let n = samples.count
        var settled: [SIMD4<Float>] = []
        if n == 1 { settled = [segment(point, point)] }
        else if n >= 3 {
            settled = continuousCurve(from: samples[n - 3], to: samples[n - 2],
                before: samples[max(0, n - 4)], after: point)
        }
        let tail = n >= 2 ? [segment(samples[n - 2], point)] : []
        try renderContinuous(settled: settled, tail: tail)
    }

    private func flushContinuous() throws {
        let n = samples.count
        guard n >= 2 else { return }
        let settled = continuousCurve(from: samples[n - 2], to: samples[n - 1],
            before: samples[max(0, n - 3)], after: samples[n - 1])
        try renderContinuous(settled: settled, tail: [])
        samples = [samples[n - 1]]
    }

    private func segment(_ a: CGPoint, _ b: CGPoint) -> SIMD4<Float> {
        SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y))
    }

    /// Adaptive chord subdivision keeps the centerline within 0.2 document pixels
    /// of the spline. Straight movement requires just one segment even at 4K.
    private func continuousCurve(from start: CGPoint, to end: CGPoint, before: CGPoint, after: CGPoint) -> [SIMD4<Float>] {
        func knot(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat { t + max(0.0001, sqrt(hypot(b.x - a.x, b.y - a.y))) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0, t1 = knot(t0, before, start), t2 = knot(t1, start, end), t3 = knot(t2, end, after)
        func point(_ u: CGFloat) -> CGPoint {
            if u == 0 { return start }; if u == 1 { return end }
            let t = t1 + (t2 - t1) * u
            let a = mix(before, start, t0, t1, t), b = mix(start, end, t1, t2, t), c = mix(end, after, t2, t3, t)
            return mix(mix(a, b, t0, t2, t), mix(b, c, t1, t3, t), t1, t2, t)
        }
        var result: [SIMD4<Float>] = []
        func subdivide(_ a: CGPoint, _ b: CGPoint, _ lo: CGFloat, _ hi: CGFloat, _ depth: Int) {
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
            func error(_ p: CGPoint) -> CGFloat {
                let t = lengthSquared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
                return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
            }
            let mid = (lo + hi) / 2, m = point(mid)
            let deviation = max(error(m), error(point((lo + mid) / 2)), error(point((mid + hi) / 2)))
            if deviation <= 0.2 || depth >= 10 { result.append(segment(a, b)); return }
            subdivide(a, m, lo, mid, depth + 1)
            subdivide(m, b, mid, hi, depth + 1)
        }
        subdivide(start, end, 0, 1, 0)
        return result
    }

    private func continuousKeys(_ segments: [SIMD4<Float>]) -> Set<Int> {
        var keys = Set<Int>()
        let reach = settings.diameter / 2 + 2
        let inverse = pixelToDocument.inverted()
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        for s in segments {
            let box = CGRect(x: CGFloat(min(s.x, s.z)), y: CGFloat(min(s.y, s.w)),
                width: CGFloat(abs(s.z - s.x)), height: CGFloat(abs(s.w - s.y)))
                .insetBy(dx: -reach, dy: -reach).intersection(canvas)
            guard !box.isNull, !box.isEmpty else { continue }
            let affected = box.applying(inverse).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !affected.isNull, !affected.isEmpty else { continue }
            for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
                for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                    keys.insert(y * columns + x)
                }
            }
        }
        return keys
    }

    private func renderContinuous(settled: [SIMD4<Float>], tail: [SIMD4<Float>]) throws {
        guard let gpu else { return }
        let tailKeys = continuousKeys(tail)
        let changed = continuousKeys(settled).union(tailKeys).union(gpuTailKeys)
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        var work: [(MetalBrushCoverage.Tile, CGRect, CGContext)] = []
        for key in changed {
            try allocateTile(key, x: key % columns, y: key / columns)
            guard let tile = tiles[key] else { continue }
            if coverage[key] == nil {
                coverage[key] = try BrushRaster.context(width: Int(tile.rect.width), height: Int(tile.rect.height), mask: true)
                gpuTiles[key] = try gpu.tile(width: Int(tile.rect.width), height: Int(tile.rect.height))
            }
            work.append((gpuTiles[key]!, tile.rect, coverage[key]!))
        }
        try gpu.render(work, settled: settled, tail: tail, mapping: pixelToDocument, settings: settings, canvas: canvas.size)
        gpuTailKeys = tailKeys
        try publish(changed)
    }

    /// Draws a straight tail to the cursor, first saving the coverage it can touch and the
    /// dab spacing state, so `removeTail()` can put both back exactly.
    private func drawTail(from start: CGPoint, to end: CGPoint, changed: inout Set<Int>) throws {
        let reach = settings.diameter / 2 + 2
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -reach, dy: -reach).intersection(canvas)
        if !box.isNull, !box.isEmpty {
            let affected = box.applying(pixelToDocument.inverted()).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !affected.isNull, !affected.isEmpty {
                let columns = (width + Self.tileSize - 1) / Self.tileSize
                for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
                    for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                        let key = y * columns + x
                        tailBackup[key] = .some(coverage[key]?.makeImage())
                    }
                }
            }
        }
        let saved = (previous, distanceToNext)
        try walk(to: end, changed: &changed)
        (previous, distanceToNext) = saved
    }

    private func removeTail() -> Set<Int> {
        var restored = Set<Int>()
        for (key, image) in tailBackup {
            guard let context = coverage[key], let tile = tiles[key] else { continue }
            let local = CGRect(origin: .zero, size: tile.rect.size)
            if let image { BrushRaster.draw(image, in: local, mask: true, context: context) }
            else { context.setFillColor(gray: 0, alpha: 1); context.fill(local) }
            dirtyTiles[key] = local
            restored.insert(key)
        }
        tailBackup = [:]
        return restored
    }

    /// Centripetal Catmull–Rom between `start` and `end`: it passes through every sample
    /// without the loops or overshoot uniform splines make at uneven mouse speeds.
    private func curve(from start: CGPoint, to end: CGPoint, before: CGPoint, after: CGPoint, changed: inout Set<Int>) throws {
        func knot(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat { t + max(0.0001, sqrt(hypot(b.x - a.x, b.y - a.y))) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0, t1 = knot(t0, before, start), t2 = knot(t1, start, end), t3 = knot(t2, end, after)
        let pieces = max(1, Int(ceil(hypot(end.x - start.x, end.y - start.y) / 2)))
        for index in 1...pieces {
            let t = t1 + (t2 - t1) * CGFloat(index) / CGFloat(pieces)
            let a1 = mix(before, start, t0, t1, t), a2 = mix(start, end, t1, t2, t), a3 = mix(end, after, t2, t3, t)
            let b1 = mix(a1, a2, t0, t2, t), b2 = mix(a2, a3, t1, t3, t)
            try walk(to: index == pieces ? end : mix(b1, b2, t1, t2, t), changed: &changed)
        }
    }

    /// Soft-tip deposition rate, shared with the continuous GPU integral.
    /// The software fallback lays actual dabs at this spacing.
    static func spacingFraction(_ hardness: CGFloat) -> CGFloat { hardness >= 1 ? 0.015 : 0.025 }

    /// Lays evenly spaced dabs along a straight run from the previous dab position.
    private func walk(to point: CGPoint, changed: inout Set<Int>) throws {
        let spacing = max(0.25, settings.diameter * Self.spacingFraction(settings.hardness))
        if let previous {
            let dx = point.x - previous.x, dy = point.y - previous.y
            let length = hypot(dx, dy)
            if length > 0 {
                var distance = distanceToNext
                while distance <= length {
                    try dab(CGPoint(x: previous.x + dx * distance / length, y: previous.y + dy * distance / length), changed: &changed)
                    distance += spacing
                }
                distanceToNext = distance - length
            }
        } else {
            try dab(point, changed: &changed)
            distanceToNext = spacing
        }
        previous = point
    }

    private func publish(_ changed: Set<Int>) throws {
        dirtyDocumentRect = nil
        for key in changed {
            if let tile = tiles[key], let coverage = coverage[key] {
                let local = CGRect(origin: .zero, size: tile.rect.size)
                // Rebuild only the touched part of the tile; the rest is already correct.
                let dirty = (dirtyTiles[key] ?? local).integral.intersection(local)
                dirtyTiles[key] = nil
                guard !dirty.isNull, !dirty.isEmpty else { continue }
                guard let mask = coverage.makeImage() else { throw ExportError.render }
                tile.context.saveGState()
                tile.context.clip(to: dirty)
                tile.context.clear(dirty)
                if let base = tile.base { BrushRaster.draw(base, in: local, mask: isMask, context: tile.context) }
                if let selectionClip {
                    tile.context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
                    tile.context.concatenate(pixelToDocument.inverted())
                    selectionClip.apply(to: tile.context)
                    tile.context.concatenate(pixelToDocument)
                    tile.context.translateBy(x: tile.rect.minX, y: tile.rect.minY)
                }
                if let clone, !isMask || isBlur {
                    // Clone Stamp: the sample, shifted by the source offset, painted through the coverage.
                    let context = tile.context
                    context.saveGState()
                    // Image masks draw bottom-up; flip so the coverage lines up with the tile.
                    context.translateBy(x: 0, y: local.height)
                    context.scaleBy(x: 1, y: -1)
                    context.clip(to: local, mask: mask)
                    context.scaleBy(x: 1, y: -1)
                    context.translateBy(x: 0, y: -local.height)
                    context.setAlpha(settings.opacity)
                    if replacesWithClone { context.setBlendMode(.copy) }
                    context.interpolationQuality = .medium
                    // Into document coordinates, where the sample lives.
                    context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
                    context.concatenate(pixelToDocument.inverted())
                    let placed = CGRect(x: -clone.offset.width, y: -clone.offset.height,
                                        width: CGFloat(clone.image.width), height: CGFloat(clone.image.height))
                    context.translateBy(x: placed.minX, y: placed.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(clone.image, in: CGRect(origin: .zero, size: placed.size))
                    context.restoreGState()
                } else if settings.healing, !isMask {
                    // While painting, the area to heal shows as a dark wash, as in Photoshop;
                    // `heal()` rebuilds it from its surroundings when the stroke ends.
                    BrushRaster.fill(Self.healingWash, coverage: mask, in: local, alpha: 0.45, context: tile.context)
                } else if settings.erasing, !isMask {
                    // Erasing takes the coverage out of the layer's alpha, leaving the pixels under it transparent.
                    tile.context.saveGState()
                    tile.context.setBlendMode(.destinationOut)
                    BrushRaster.fill(Self.eraseColor, coverage: mask, in: local, alpha: settings.opacity, context: tile.context)
                    tile.context.restoreGState()
                } else {
                    BrushRaster.fill(paintColor, coverage: mask, in: local, alpha: settings.opacity, context: tile.context)
                }
                tile.context.restoreGState()
            }
            guard let image = tiles[key]?.context.makeImage() else { throw ExportError.render }
            tiles[key]?.image = image
            if let rect = tiles[key]?.rect.applying(pixelToDocument).intersection(canvas) {
                dirtyDocumentRect = dirtyDocumentRect.map { $0.union(rect) } ?? rect
            }
        }
    }

    private static let eraseColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let healingWash = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)

    private func dab(_ point: CGPoint, changed: inout Set<Int>) throws {
        let radius = settings.diameter / 2
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        let clipped = circle.intersection(canvas)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        let inverse = pixelToDocument.inverted()
        let pixelCanvas = canvas.applying(inverse)
        // Snapped to whole pixels so the tip lands 1:1 with nothing to resample. The tip is
        // radially symmetric, so the layer's flip is harmless, and half a pixel of placement
        // sits far below what a dab's soft rim resolves.
        let blit: CGRect? = gridTip.map { tip in
            let center = point.applying(inverse)
            return CGRect(x: (center.x - CGFloat(tip.width) / 2).rounded(),
                          y: (center.y - CGFloat(tip.height) / 2).rounded(),
                          width: CGFloat(tip.width), height: CGFloat(tip.height))
        }
        let affected = (blit ?? clipped.applying(inverse)).intersection(pixelCanvas)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !affected.isNull, !affected.isEmpty else { return }
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
            for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                let key = y * columns + x
                try allocateTile(key, x: x, y: y)
                guard let tile = tiles[key] else { continue }
                let touched = affected.intersection(tile.rect).offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY)
                if !touched.isNull, !touched.isEmpty {
                    dirtyTiles[key] = dirtyTiles[key].map { $0.union(touched) } ?? touched
                }
                if coverage[key] == nil {
                    let layer = try BrushRaster.context(width: Int(tile.rect.width), height: Int(tile.rect.height), mask: true)
                    layer.clear(CGRect(origin: .zero, size: tile.rect.size))
                    coverage[key] = layer
                }
                guard let context = coverage[key] else { continue }
                context.saveGState()
                if let gridTip, let blit {
                    context.clip(to: pixelCanvas.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY))
                    context.setBlendMode(settings.hardness >= 1 ? .lighten : .screen)
                    context.interpolationQuality = .none
                    context.draw(gridTip, in: blit.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY))
                    context.restoreGState()
                    changed.insert(key)
                    continue
                }
                context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
                context.concatenate(inverse)
                context.clip(to: canvas)
                context.setBlendMode(settings.hardness >= 1 ? .lighten : .screen)
                if let stamp {
                    // Stamp the pre-rendered tip: drawing the falloff procedurally for every
                    // dab (a 60 px brush lays ~14 per mouse move) is what made strokes stutter.
                    context.interpolationQuality = .low
                    context.draw(stamp, in: circle)
                } else if settings.hardness >= 1 {
                    context.setFillColor(gray: 1, alpha: 1)
                    context.fillEllipse(in: circle)
                } else if let falloff {
                    context.drawRadialGradient(falloff, startCenter: point, startRadius: radius * settings.hardness,
                        endCenter: point, endRadius: radius, options: [.drawsBeforeStartLocation])
                }
                context.restoreGState()
                changed.insert(key)
            }
        }
    }

    private func allocateTile(_ key: Int, x: Int, y: Int) throws {
        guard tiles[key] == nil else { return }
        let size = Self.tileSize
        let rect = CGRect(x: x * size, y: y * size, width: min(size, width - x * size), height: min(size, height - y * size))
        let nextBounds = allocatedBounds.map { $0.union(rect) } ?? (source == nil ? rect : sourceRect.union(rect))
        guard nextBounds.width <= 30_000, nextBounds.height <= 30_000,
              nextBounds.width * nextBounds.height <= CGFloat(pixelLimit) else { throw ProjectError.tooLarge }
        allocatedBounds = nextBounds
        let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: isMask)
        if let raster = (isMask ? layer.mask?.asset.raster : layer.asset?.raster) {
            raster.draw(in: sourceRect.offsetBy(dx: -rect.minX, dy: -rect.minY), context: context)
        } else if let source {
            // Draw just this tile's share of the source. Handing Core Graphics the whole
            // image (up to 30k px) for every new tile is what made long strokes stutter;
            // cropping first is free and leaves a 256 px blit. Uniform 1×1 masks are
            // stretched over the layer, so they are drawn whole.
            let initialRect = sourceRect.offsetBy(dx: -rect.minX, dy: -rect.minY)
            let overlap = rect.intersection(sourceRect)
            if source.width > 2, source.height > 2, !overlap.isNull, !overlap.isEmpty {
                let scaleX = CGFloat(source.width) / sourceRect.width
                let scaleY = CGFloat(source.height) / sourceRect.height
                let crop = CGRect(x: (overlap.minX - sourceRect.minX) * scaleX,
                                  y: (overlap.minY - sourceRect.minY) * scaleY,
                                  width: overlap.width * scaleX, height: overlap.height * scaleY).integral
                if let cropped = source.cropping(to: crop) {
                    BrushRaster.draw(cropped, in: overlap.offsetBy(dx: -rect.minX, dy: -rect.minY),
                                     mask: isMask, context: context)
                } else {
                    BrushRaster.draw(source, in: initialRect, mask: isMask, context: context)
                }
            } else {
                BrushRaster.draw(source, in: initialRect, mask: isMask, context: context)
            }
        }
        tiles[key] = Tile(rect: rect, context: context, base: context.makeImage())
    }

    /// Replaces this edit with a gradient over the whole canvas (or the selection),
    /// composited onto the original pixels. Redrawing restarts from each tile's original
    /// content, so moving the line never accumulates earlier previews.
    func fillGradient(_ shape: GradientShape, from start: CGPoint, to end: CGPoint, colors: [CGColor], opacity: CGFloat) throws {
        let space = isMask ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) else { throw ExportError.render }
        try paintCanvas { context in
            context.setAlpha(min(1, max(0, opacity)))
            switch shape {
            case .linear:
                context.drawLinearGradient(gradient, start: start, end: end,
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial:
                context.drawRadialGradient(gradient, startCenter: start, startRadius: 0, endCenter: start,
                                           endRadius: hypot(end.x - start.x, end.y - start.y),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
    }

    /// Fills the selection (or the whole canvas) with a solid color.
    func fill(_ color: CGColor, clip: SelectionClip? = nil) throws {
        try paintCanvas(region: clip?.rect) { context in
            clip?.apply(to: context)
            context.setFillColor(color)
            context.fill(self.canvas)
        }
    }

    /// Erases image pixels to transparency inside the selection, only where pixels exist.
    func clearPixels() throws {
        try paintCanvas(withinSource: true) { context in
            context.setBlendMode(.destinationOut)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(self.canvas)
        }
    }

    /// Runs `draw` in document coordinates over every tile the canvas and selection
    /// cover (only the layer's existing pixels with `withinSource`), clipped to both,
    /// starting from each tile's original content.
    private func paintCanvas(withinSource: Bool = false, region: CGRect? = nil, _ draw: (CGContext) throws -> Void) throws {
        var area = region.map { canvas.intersection($0) } ?? canvas
        if let selectionClip { area = area.intersection(selectionClip.rect) }
        guard !area.isNull, !area.isEmpty else { return }
        let inverse = pixelToDocument.inverted()
        var affected = area.applying(inverse).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if withinSource { affected = affected.intersection(sourceRect) }
        guard !affected.isNull, !affected.isEmpty else { return }
        let columns = (width + Self.tileSize - 1) / Self.tileSize
        for y in Int(affected.minY) / Self.tileSize...Int(ceil(affected.maxY) - 1) / Self.tileSize {
            for x in Int(affected.minX) / Self.tileSize...Int(ceil(affected.maxX) - 1) / Self.tileSize {
                let key = y * columns + x
                try allocateTile(key, x: x, y: y)
                guard let tile = tiles[key] else { continue }
                let context = tile.context
                let local = CGRect(origin: .zero, size: tile.rect.size)
                context.clear(local)
                if source != nil, let base = tile.base { BrushRaster.draw(base, in: local, mask: isMask, context: context) }
                context.saveGState()
                context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
                context.concatenate(inverse)
                context.clip(to: canvas)
                selectionClip?.apply(to: context)
                try draw(context)
                context.restoreGState()
                guard let image = context.makeImage() else { throw ExportError.render }
                tiles[key]?.image = image
            }
        }
        dirtyDocumentRect = canvas
    }

    // MARK: Moving selected pixels

    /// Selected image pixels cut out of the layer, in layer pixel coordinates.
    private var lifted: (image: CGImage, rect: CGRect)?
    private var moveTiles = Set<Int>()

    /// Cuts the selected pixels out of the original image. False when nothing is lifted.
    func liftSelection() throws -> Bool {
        guard !isMask, let source, let selectionClip, selectionClip.coverage != nil else { return false }
        let inverse = pixelToDocument.inverted()
        let region = selectionClip.rect.applying(inverse).integral.intersection(sourceRect)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return false }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.concatenate(inverse)
        selectionClip.apply(to: context)
        context.concatenate(pixelToDocument)
        context.translateBy(x: region.minX, y: region.minY)
        BrushRaster.draw(source, in: sourceRect.offsetBy(dx: -region.minX, dy: -region.minY), mask: false, context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        lifted = (image, region)
        return true
    }

    /// Rebuilds the affected tiles from the original: the selection becomes a transparent
    /// hole and the lifted pixels are placed `offset` document pixels away.
    func moveLifted(by offset: CGSize, duplicate: Bool = false) throws {
        guard let lifted, let selectionClip else { return }
        let inverse = pixelToDocument.inverted()
        let zero = CGPoint.zero.applying(inverse)
        let moved = CGPoint(x: offset.width, y: offset.height).applying(inverse)
        let target = lifted.rect.offsetBy(dx: moved.x - zero.x, dy: moved.y - zero.y)
        let whole = target.minX == target.minX.rounded() && target.minY == target.minY.rounded()
        let needed = lifted.rect.union(target).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        var keys = moveTiles
        if !needed.isNull, !needed.isEmpty {
            let columns = (width + Self.tileSize - 1) / Self.tileSize
            for y in Int(needed.minY) / Self.tileSize...Int(ceil(needed.maxY) - 1) / Self.tileSize {
                for x in Int(needed.minX) / Self.tileSize...Int(ceil(needed.maxX) - 1) / Self.tileSize {
                    let key = y * columns + x
                    try allocateTile(key, x: x, y: y)
                    keys.insert(key)
                }
            }
        }
        for key in keys {
            guard let tile = tiles[key] else { continue }
            let context = tile.context
            let local = CGRect(origin: .zero, size: tile.rect.size)
            context.clear(local)
            if let base = tile.base { BrushRaster.draw(base, in: local, mask: false, context: context) }
            context.saveGState()
            context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
            context.concatenate(inverse)
            selectionClip.apply(to: context)
            context.setBlendMode(.destinationOut)
            context.setFillColor(gray: 0, alpha: 1)
            if !duplicate { context.fill(selectionClip.rect) }
            context.restoreGState()
            context.saveGState()
            context.interpolationQuality = whole ? .none : .high
            context.translateBy(x: target.minX - tile.rect.minX, y: target.maxY - tile.rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.draw(lifted.image, in: CGRect(origin: .zero, size: target.size))
            context.restoreGState()
            guard let image = context.makeImage() else { throw ExportError.render }
            tiles[key]?.image = image
        }
        moveTiles = keys
        dirtyDocumentRect = canvas
    }

    var committedBounds: CGRect { (allocatedBounds ?? sourceRect).integral }
    var committedTransform: LayerTransform { transform(for: committedBounds) }
    func transform(for bounds: CGRect) -> LayerTransform {
        let center = CGPoint(x: bounds.midX, y: bounds.midY).applying(pixelToDocument)
        var result = paintTransform
        result.size = CGSize(width: bounds.width * paintTransform.size.width / CGFloat(width),
                             height: bounds.height * paintTransform.size.height / CGFloat(height))
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        return result
    }
    /// Spot Healing, once the stroke ends: rebuilds the painted area from nearby texture
    /// (`HealPixels.c`) and writes it into the stroke's tiles, so the usual commit applies it as
    /// one undo step. Reads the layer's original pixels, never the dark wash shown while painting.
    func heal() throws {
        guard settings.healing, !isMask else { return }
        var painted: CGRect?
        for (key, context) in coverage {
            guard let tile = tiles[key], let data = context.data else { continue }
            var edges = [Int](repeating: 0, count: 4)
            heal_coverage_bounds(data.assumingMemoryBound(to: UInt8.self), Int(tile.rect.width), Int(tile.rect.height),
                                 context.bytesPerRow, &edges)
            guard edges[2] > edges[0], edges[3] > edges[1] else { continue }
            let rect = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
                .offsetBy(dx: tile.rect.minX, dy: tile.rect.minY)
            painted = painted.map { $0.union(rect) } ?? rect
        }
        guard let painted else { return }
        // Room for the kernel's patch search, which looks up to about three spot-widths away.
        let reach = (max(painted.width, painted.height) + 32) * 3.2
        let region = painted.insetBy(dx: -reach, dy: -reach)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let w = Int(region.width), h = Int(region.height)
        let pixels = try BrushRaster.context(width: w, height: h, mask: false)
        let placed = sourceRect.offsetBy(dx: -region.minX, dy: -region.minY)
        if let raster = layer.asset?.raster { raster.draw(in: placed, context: pixels) }
        else if let source { BrushRaster.draw(source, in: placed, mask: false, context: pixels) }
        let painting = try BrushRaster.context(width: w, height: h, mask: true)
        for (key, context) in coverage {
            guard let tile = tiles[key], let image = context.makeImage() else { continue }
            BrushRaster.draw(image, in: tile.rect.offsetBy(dx: -region.minX, dy: -region.minY), mask: true, context: painting)
        }
        guard let rgba = pixels.data, let gray = painting.data else { throw ExportError.render }
        let mode = Int32(SpotHealingMode.allCases.firstIndex(of: settings.healingMode) ?? 0)
        guard spot_heal(rgba.assumingMemoryBound(to: UInt8.self), gray.assumingMemoryBound(to: UInt8.self), w, h,
                        pixels.bytesPerRow, Float(settings.opacity), mode, UInt32.random(in: .min ... .max)) == 0 else {
            throw ProjectError.tooLarge
        }
        guard let healed = pixels.makeImage() else { throw ExportError.render }
        for key in coverage.keys {
            guard let tile = tiles[key] else { continue }
            let local = CGRect(origin: .zero, size: tile.rect.size)
            let context = tile.context
            context.saveGState()
            context.clear(local)
            if let base = tile.base { BrushRaster.draw(base, in: local, mask: false, context: context) }
            if let selectionClip {
                context.translateBy(x: -tile.rect.minX, y: -tile.rect.minY)
                context.concatenate(pixelToDocument.inverted())
                selectionClip.apply(to: context)
                context.concatenate(pixelToDocument)
                context.translateBy(x: tile.rect.minX, y: tile.rect.minY)
            }
            BrushRaster.draw(healed, in: region.offsetBy(dx: -tile.rect.minX, dy: -tile.rect.minY), mask: false, context: context)
            context.restoreGState()
            tiles[key]?.image = context.makeImage()
        }
    }

    /// Painting only adds alpha. Existing content bounds remain valid, so only the
    /// changed 256px tiles need inspecting; there is no full-document bounds scan.
    func paintSnapshot() throws -> (asset: ImportedImage, transform: LayerTransform, bounds: CGRect) {
        var bounds: CGRect? = source == nil ? nil : sourceRect
        for tile in tiles.values where !isMask {
            guard let bytes = tile.context.data else { throw ExportError.render }
            var edges = [Int](repeating: 0, count: 4)
            brush_alpha_bounds(bytes.assumingMemoryBound(to: UInt8.self), Int(tile.rect.width), Int(tile.rect.height), tile.context.bytesPerRow, &edges)
            guard edges[2] > edges[0], edges[3] > edges[1] else { continue }
            let rect = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
                .offsetBy(dx: tile.rect.minX, dy: tile.rect.minY)
            bounds = bounds.map { $0.union(rect) } ?? rect
        }
        let crop = bounds ?? committedBounds
        let raster = RasterSnapshot.replacing(source: isMask ? layer.mask?.asset : layer.asset, sourceRect: sourceRect, patches: patches, crop: crop, isMask: isMask)
        let image = try raster.makeImage()
        return (ImportedImage(image: image, thumbnail: try raster.thumbnail(), name: layer.name, raster: raster), transform(for: crop), crop)
    }

    func commitInput() -> BrushCommit.Input {
        let bounds = committedBounds
        return BrushCommit.Input(width: Int(bounds.width), height: Int(bounds.height), source: source,
            patches: patches.map { BrushPatch(rect: $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), image: $0.image) },
            mask: isMask, name: layer.name, sourceRect: sourceRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
    }
}

actor BrushCommit {
    static let shared = BrushCommit()
    nonisolated struct Input: @unchecked Sendable {
        let width: Int, height: Int
        let source: CGImage?
        let patches: [BrushPatch]
        let mask: Bool
        let name: String
        let sourceRect: CGRect
    }
    nonisolated struct Output: @unchecked Sendable {
        let asset: ImportedImage
        let pixelBounds: CGRect
    }
    func expandMask(_ asset: ImportedImage, for input: Input, croppedTo crop: CGRect) throws -> ImportedImage {
        if input.sourceRect == crop { return asset }
        let bounds = CGRect(origin: .zero, size: crop.size)
        let context = try BrushRaster.context(width: Int(crop.width), height: Int(crop.height), mask: true)
        // New canvas area has no pre-existing mask restriction. Existing coverage stays aligned.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        BrushRaster.draw(asset.image, in: input.sourceRect.offsetBy(dx: -crop.minX, dy: -crop.minY), mask: true, context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return try LayerMask.asset(from: image)
    }
    func render(_ input: Input) throws -> Output {
        let context = try BrushRaster.context(width: input.width, height: input.height, mask: input.mask)
        if let source = input.source {
            BrushRaster.draw(source, in: input.sourceRect, mask: input.mask, context: context)
        }
        for patch in input.patches { BrushRaster.draw(patch.image, in: patch.rect, mask: input.mask, context: context) }
        guard let fullImage = context.makeImage() else { throw ExportError.render }
        let fullBounds = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        if input.mask { return Output(asset: try LayerMask.asset(from: fullImage), pixelBounds: fullBounds) }
        // Scan once on the commit actor, never during pointer movement. Keep every
        // nonzero-alpha pixel, including the faint outer edge of a soft brush.
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var edges = [Int](repeating: 0, count: 4)
        brush_alpha_bounds(bytes, input.width, input.height, context.bytesPerRow, &edges)
        let crop = edges[2] <= edges[0] ? fullBounds : CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
        let image: CGImage
        if crop == fullBounds { image = fullImage }
        else {
            guard let cropped = fullImage.cropping(to: crop) else { throw ExportError.render }
            // A CGImage crop can retain the full backing allocation. Copy just the
            // tight raster so small painted layers do not retain large empty buffers.
            let tight = try BrushRaster.context(width: Int(crop.width), height: Int(crop.height), mask: false)
            BrushRaster.draw(cropped, in: CGRect(origin: .zero, size: crop.size), mask: false, context: tight)
            guard let result = tight.makeImage() else { throw ExportError.render }
            image = result
        }
        let factor = min(1, 96 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        let thumb = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: thumb)
        guard let thumbnail = thumb.makeImage() else { throw ExportError.render }
        return Output(asset: ImportedImage(image: image, thumbnail: thumbnail, name: input.name), pixelBounds: crop)
    }
}
