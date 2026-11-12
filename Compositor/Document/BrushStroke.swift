import AppKit

/// Optional tablet channels; absence is never a fabricated tilt or barrel angle. Rotation is in radians.
nonisolated struct BrushInput: Equatable, Sendable {
    let pressure: CGFloat?
    let tilt: CGPoint?
    let rotation: CGFloat?
    let timestamp: TimeInterval?
    let deviceID: Int?
    var effectivePressure: CGFloat { pressure ?? 1 }

    init(pressure: CGFloat? = nil, tilt: CGPoint? = nil, rotation: CGFloat? = nil,
         timestamp: TimeInterval? = nil, deviceID: Int? = nil) {
        self.pressure = pressure.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.tilt = tilt.flatMap { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1 && abs($0.y) <= 1 ? $0 : nil }
        self.rotation = rotation.flatMap { $0.isFinite ? Self.wrappedAngle($0) : nil }
        self.timestamp = timestamp.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.deviceID = deviceID
    }
    static func wrappedAngle(_ value: CGFloat) -> CGFloat { atan2(sin(value), cos(value)) }

    func monotonic(after previous: TimeInterval?) -> BrushInput {
        BrushInput(pressure: pressure, tilt: tilt, rotation: rotation,
            timestamp: timestamp.map { max(previous ?? $0, $0) }, deviceID: deviceID)
    }

    func interpolated(to other: BrushInput, fraction: CGFloat) -> BrushInput {
        let t = fraction.isFinite ? min(1, max(0, fraction)) : 0
        func mix(_ a: CGFloat?, _ b: CGFloat?) -> CGFloat? {
            guard let a, let b else { return nil }
            return a + (b - a) * t
        }
        let time: TimeInterval?
        if let timestamp, let end = other.timestamp { time = timestamp + (max(timestamp, end) - timestamp) * Double(t) }
        else { time = nil }
        guard deviceID == other.deviceID else { return BrushInput(timestamp: time) }
        let angle: CGFloat?
        if let rotation, let end = other.rotation { angle = rotation + Self.wrappedAngle(end - rotation) * t }
        else { angle = nil }
        let vector: CGPoint?
        if let tilt, let end = other.tilt { vector = CGPoint(x: tilt.x + (end.x - tilt.x) * t, y: tilt.y + (end.y - tilt.y) * t) }
        else { vector = nil }
        return BrushInput(pressure: mix(pressure, other.pressure), tilt: vector, rotation: angle, timestamp: time, deviceID: deviceID)
    }
}

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
    /// Blur: how far it softens, in canvas pixels, whatever the brush's size. Strength sets how much.
    var blurRadius: CGFloat = 5
    /// Spot-healing uses nearby source pixels instead of the foreground color.
    /// Erase: the stroke clears the layer's pixels instead of painting color on them.
    var erasing = false
    var healing = false
    var healingMode: SpotHealingMode = .contentAware
    /// A pen's pressure sets the size of each part of the stroke, and how strongly it lays down, as Photoshop's two
    /// pressure buttons do. A mouse or trackpad always presses fully.
    var pressureSize = false
    var pressureOpacity = false
    var roundDynamics = RoundBrushDynamics()
    var shapeTip: BrushShapeTip? = nil
    var secondaryShapeTip: BrushShapeTip? = nil
    var grainTip: BrushShapeTip? = nil

    var usesStampDynamics: Bool {
        roundDynamics.usesStamps || ((pressureSize || pressureOpacity) && !roundDynamics.pressureCurve.isIdentity)
    }

    /// What a press of `pressure` (0–1) does to the tip: its size as a share of the full diameter, and its strength.
    func dynamics(_ pressure: CGFloat?) -> (scale: CGFloat, strength: CGFloat) {
        let pressure = pressure.map { roundDynamics.pressureCurve.value($0) } ?? 1
        let properties = roundDynamics.properties
        let sizeFloor = min(1, (properties?.minimumSize ?? 1) / diameter)
        let strength = pressureOpacity ? pressure : 1
        // Never smaller than a pixel across, so the lightest touch still leaves a line.
        return (pressureSize ? max(pressure, sizeFloor) : 1, max(min(1, (properties?.minimumOpacity ?? 0) / max(0.01, opacity)), strength))
    }
}

/// One piece of a continuous stroke for the GPU: the line, and the tip's radius and strength at each end.
struct BrushSegment {
    var line: SIMD4<Float>
    var dynamics: SIMD4<Float>
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
    /// A color context holding `image`'s pixels. An image already in this layout (one made from such a context)
    /// is copied byte for byte, several times quicker than drawing it.
    static func copy(_ image: CGImage) throws -> CGContext {
        let context = try Self.context(width: image.width, height: image.height, mask: false)
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8, image.bitmapInfo == context.bitmapInfo,
              image.colorSpace == context.colorSpace, let source = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(source), let target = context.data,
              CFDataGetLength(source) >= image.bytesPerRow * (image.height - 1) + image.width * 4 else {
            draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
            return context
        }
        let row = image.width * 4
        for y in 0..<image.height {
            memcpy(target + y * context.bytesPerRow, bytes + y * image.bytesPerRow, row)
        }
        return context
    }

    /// Runs `body` over `count` pixels in a few bands at once, each a (start, length) of whole pixels.
    static func inBands(count: Int, _ body: (Int, Int) -> Void) {
        let bands = count < 250_000 ? 1 : ProcessInfo.processInfo.activeProcessorCount * 2
        let size = (count + bands - 1) / bands
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let start = band * size
            if start < count { body(start, min(size, count - start)) }
        }
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
        CGFloat(brush_tip_falloff(Double(u)))
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
    let seed: UInt64
    private let grainMask: Data?
    private let grainSide: Int
    private let shapeMask: Data?
    private let shapeSide: Int
    private let shapeHasInk: Bool
    private let secondaryMask: Data?
    private let secondarySide: Int
    private var carriedColor: SIMD3<Float>? = nil
    private var pickupSelectionImage: CGImage?
    private var pickupSelectionData: Data?
    private var firstBarrel: CGFloat?
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
    /// The options bar stops Size at 2000; strokes the app lays itself, such as committing a Smudge or Liquify at that
    /// size, run a little wider.
    static let maxDiameter: CGFloat = 2100
    var pixelLimit = DocumentLimits.documentPixelBudget
    /// For a layer scaled down: how many pixels it may grow to, at its own resolution, as paint goes past its edges.
    /// Past this the stroke throws `OutgrewItsResolution`, and the session paints it again on the layer at its displayed
    /// size. Nil to grow freely.
    var growthLimit: Int?
    /// A scaled-down layer grown past `growthLimit`: at its own resolution it would take far more pixels than it shows.
    struct OutgrewItsResolution: Error {}
    /// The layer as it was in the document when the stroke began, which `layer` stands in for once the stroke has been
    /// started again on it at its displayed size.
    var originalLayer: ImageLayer
    var usesGPU: Bool { gpu != nil }
    /// Limits every edit to the document selection; nil when nothing is selected.
    var selectionClip: SelectionClip?
    /// Clone Stamp, Blur, Smudge and Liquify: an image painted through the tip, and where it sits, already shifted
    /// by any source offset. Either in document pixels (a composite of the canvas, at document size) or, `inGrid`,
    /// in the stroke's own pixel grid: the layer's own pixels at their own resolution, so a layer scaled down and
    /// painted keeps its detail when it's scaled back up.
    var clone: (image: CGImage, placed: CGRect, inGrid: Bool)? { didSet { clonePieces = [:] } }
    /// Makes part of `clone`'s image, given a rect of its pixels (top-left rows), in place of cropping it: Blur softens
    /// the layer a piece at a time as the brush first reaches it, rather than all of it before the first dab.
    var cloneRender: ((CGRect) -> CGImage?)? { didSet { clonePieces = [:] } }
    /// The part of `clone` each tile draws, cut once: drawing the whole sample into every tile the brush touched,
    /// a 25-megapixel image drawn dozens of times per mouse move, is what made big strokes crawl.
    private var clonePieces: [Int: (image: CGImage, placed: CGRect)] = [:]
    /// The same sample at 16 bits, for a 16-bit layer (`DeepLayer`): the stroke's commit paints it into the layer's
    /// 16-bit pixels through the same coverage, so Blur, Smudge and Liquify keep the layer's precision where they go.
    var deepClone: (image: CGImage, placed: CGRect, inGrid: Bool)?
    /// Makes part of `deepClone`'s image, as `cloneRender` does for `clone`'s.
    var deepCloneRender: ((CGRect) -> CGImage?)?
    /// A Blur stroke: `clone` holds the layer blurred, painted in place through the tip.
    var isBlur = false
    /// The clone sample replaces what's under the tip rather than drawing over it, so it can also clear pixels.
    var replacesWithClone = false
    /// The undo name, when the stroke's kind doesn't say it.
    var editName: String?
    /// The last drawing laid over the whole canvas (a gradient, a fill, a clear), in document coordinates, to draw again
    /// into a 16-bit layer's 16-bit pixels when the edit is committed (`BrushCommit`), rather than taking its 8-bit tiles.
    private var canvasPaint: (draw: (CGContext) throws -> Void, withinSource: Bool)?
    private var allocatedBounds: CGRect?
    private var previous: CGPoint?
    private var samples: [CGPoint] = []
    /// Bounded sample metadata survives until its curve segment is settled.
    private(set) var inputSamples: [BrushInput] = []
    private(set) var lastInput: BrushInput?
    private var lastTimestamp: TimeInterval?
    private var previousWalkInput = BrushInput()
    /// Coverage under the provisional tail; nil where the tile had no coverage yet.
    private var tailBackup: [Int: CGImage?] = [:]
    private struct StampedCoverage {
        var density: [Float]
        var cap: [Float]
        var pigment: [Float] = []
        var edge: [Float] = []

    }
    private var stampedCoverage: [Int: StampedCoverage] = [:]
    private var stampedTailBackup: [Int: StampedCoverage?] = [:]
    private var travelled: CGFloat = 0
    private(set) var dabIndex = 0
    private var taperDabs: [(point: CGPoint, input: BrushInput, direction: CGPoint, distance: CGFloat)] = []
    private var taperFinalized = false
    /// Recorded previews need only the completed taper, never intermediate untapered pixels.
    var defersTaperRendering = false
    private static let maxDabs = 250_000
    private var stampedPadding: CGFloat { hypot(pixelToDocument.a, pixelToDocument.b) + hypot(pixelToDocument.c, pixelToDocument.d) }
    private var shapeExtent: CGFloat {
        let rendering = settings.roundDynamics.renderingSettings
        let primary = shapeMask == nil ? 1 : sqrt(2) * (1 + (settings.roundDynamics.shapeSettings.filtering == .none ? 0 : 1 / CGFloat(shapeSide)))
        let secondary = secondarySide == 0 ? 0 : sqrt(2) * rendering.secondaryScale * (1 + 1 / CGFloat(secondarySide))
        return max(primary, secondary) + sqrt(2) * 0.2 * rendering.wetEdges
    }
    private var distanceToNext: CGFloat = 0
    private(set) var dirtyDocumentRect: CGRect?
    private struct Tile { let rect: CGRect; let context: CGContext; var image: CGImage?; let base: CGImage?; var basePixels: Data? = nil }
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

    /// `growsMask`: a brush on a mask can paint anywhere on the canvas, as Photoshop's does, growing the mask past its
    /// layer. Other edits of a mask stay within it.
    init(layer: ImageLayer, mask: Bool, settings: BrushSettings, canvas: CGSize, useGPU: Bool = true, growsMask: Bool = false, seed: UInt64 = 0) throws {
        var settings = settings
        if let properties = settings.roundDynamics.properties, properties.isValid {
            settings.diameter = min(properties.maximumSize, max(properties.minimumSize, settings.diameter))
            settings.opacity = min(properties.maximumOpacity, max(properties.minimumOpacity, settings.opacity))
        }
        gpu = useGPU && !settings.usesStampDynamics ? MetalBrushCoverage.shared : nil
        self.seed = seed
        let shape = settings.roundDynamics.shapeSettings
        let tip = shape.source == .custom ? shape.customTip : shape.source == .generated ? shape.generatedKind.make() : settings.shapeTip
        guard shape.source == .procedural || tip?.isValid == true else {
            throw NSError(domain: "BrushShape", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected shape image is missing or invalid. Choose a source in Shape settings."])
        }
        let maskData = shape.source == .procedural ? nil : tip?.mask(shape.source == .generated ? .luminance : shape.mask)
        let rendering = settings.roundDynamics.renderingSettings
        let secondary = rendering.dualSource == .generated ? rendering.secondary.make() : settings.secondaryShapeTip
        guard rendering.dualSource == nil || secondary?.isValid == true else {
            throw NSError(domain: "BrushRendering", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected secondary shape is missing or invalid."])
        }
        secondaryMask = rendering.dualSource == nil ? nil : secondary?.luminance
        secondarySide = rendering.dualSource == nil ? 0 : secondary?.side ?? 0
        let grain = settings.roundDynamics.grain
        let texture = grain?.source == .generated ? BrushGrain.texture() : grain?.source == .custom ? grain?.custom : settings.grainTip
        guard grain == nil || texture?.isValid == true else {
            throw NSError(domain: "BrushGrain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected grain image is missing or invalid. Choose a grain source."])
        }
        grainMask = grain == nil ? nil : texture?.luminance
        grainSide = grain == nil ? 0 : texture?.side ?? 0
        shapeMask = maskData
        shapeHasInk = (maskData?.contains(where: { $0 != 0 }) ?? true)
            || (rendering.classicDualNormal && rendering.dualSource != nil && secondary?.luminance.contains(where: { $0 != 0 }) == true)
        shapeSide = shape.source == .procedural ? 0 : tip?.side ?? 0
        self.layer = layer
        originalLayer = layer
        isMask = mask
        self.settings = settings
        self.canvas = CGRect(origin: .zero, size: canvas)
        // A mask on its own placement is painted in its own pixel grid; otherwise the grid is the layer's.
        let placedMask = mask ? layer.mask.flatMap { mask in mask.placement.map { (mask.asset.image, $0) } } : nil
        let base = placedMask?.1 ?? layer.transform
        // A solid mask is a single pixel stretched over its place; painted, it gets one pixel per document pixel.
        let solidPlaced = placedMask.map { $0.0.width <= 2 && $0.0.height <= 2 } == true
        let originalWidth = solidPlaced ? max(1, Int(base.size.width.rounded()))
            : placedMask?.0.width ?? layer.asset?.image.width ?? Int(layer.size.width.rounded())
        let originalHeight = solidPlaced ? max(1, Int(base.size.height.rounded()))
            : placedMask?.0.height ?? layer.asset?.image.height ?? Int(layer.size.height.rounded())
        let originalMapping = BrushRaster.pixelToDocument(base, width: originalWidth, height: originalHeight)
        let originalBounds = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
        let extent = mask && !growsMask ? originalBounds : originalBounds.union(self.canvas.applying(originalMapping.inverted()).integral)
        // What a mask is past its pixels, and so what new mask area starts as: white reveals, black hides.
        maskBackground = mask ? layer.mask.map { LayerMask.background(of: $0.asset.thumbnail) } ?? 1 : 1
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
              (1...DocumentLimits.maxSide).contains(originalWidth), (1...DocumentLimits.maxSide).contains(originalHeight),
              settings.diameter.isFinite, (1...Self.maxDiameter).contains(settings.diameter),
              settings.hardness.isFinite, (0...1).contains(settings.hardness),
              settings.opacity.isFinite, (0.01...1).contains(settings.opacity), settings.roundDynamics.isValid else { throw ProjectError.tooLarge }
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
        gridTip = gpu == nil && !settings.usesStampDynamics && square && gridDiameter >= 1 && gridDiameter <= Self.gridTipLimit
            ? try Self.tip(diameter: gridDiameter, hardness: settings.hardness, falloff: falloff) : nil
        // Drawn through the tile transform, the stamp is rendered as finely as the layer's pixels: magnified onto
        // the finer grid of a scaled-down layer, it left blocky dabs that showed once the layer was scaled back up.
        let stampDiameter = settings.diameter / min(1, scaleX, scaleY)
        stamp = gpu == nil && !settings.usesStampDynamics && gridTip == nil && stampDiameter <= Self.stampLimit
            ? try Self.tip(diameter: stampDiameter, hardness: settings.hardness, falloff: falloff) : nil
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
    func append(_ point: CGPoint, pressure: CGFloat = 1) throws {
        try append(point, input: BrushInput(pressure: pressure))
    }
    private func changesDab(from old: BrushInput, to new: BrushInput) -> Bool {
        if old.effectivePressure != new.effectivePressure { return true }
        let path = settings.roundDynamics.path
        let shape = settings.roundDynamics.shapeSettings
        func uses(_ input: StrokePathSettings.Input) -> Bool {
            (path.lateralJitter > 0 && path.lateralInput == input) || (path.linearJitter > 0 && path.linearInput == input)
        }
        return ((uses(.tilt) || shape.inputStyle != .touch || shape.tiltRoundness > 0) && old.tilt != new.tilt)
            || ((uses(.rotation) || shape.inputStyle == .barrel) && old.rotation != new.rotation)
    }
    func append(_ point: CGPoint, input: BrushInput) throws {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000 else { return }
        taperFinalized = false
        let input = input.monotonic(after: lastTimestamp)
        lastTimestamp = input.timestamp ?? lastTimestamp
        lastInput = input
        if firstBarrel == nil { firstBarrel = input.rotation }
        if samples.last == point, let last = inputSamples.last, !changesDab(from: last, to: input) {
            inputSamples[inputSamples.count - 1] = input
            return
        }
        if gpu != nil { try appendContinuous(point, input: input); return }
        var changed = removeTail()
        samples.append(point)
        inputSamples.append(input)
        if samples.count > 4 { samples.removeFirst(); inputSamples.removeFirst() }
        let count = samples.count
        if count == 1 {
            try walk(to: point, input: input, changed: &changed)
        } else if count >= 3 {
            try curve(from: samples[count - 3], to: samples[count - 2],
                      before: samples[max(0, count - 4)], after: samples[count - 1],
                      inputs: (inputSamples[count - 3], inputSamples[count - 2]), changed: &changed)
        }
        if !(defersTaperRendering && settings.roundDynamics.hasTaper) {
            if count >= 2 { try drawTail(from: samples[count - 2], to: point, input: input, changed: &changed) }
            try publish(changed)
        }
    }

    /// Replaces the provisional tail with the stroke's final curve piece. Safe to repeat.
    func flush() throws {
        if gpu != nil { try flushContinuous(); return }
        var changed = removeTail()
        let count = samples.count
        if count >= 2 {
            try curve(from: samples[count - 2], to: samples[count - 1],
                      before: samples[max(0, count - 3)], after: samples[count - 1],
                      inputs: (inputSamples[count - 2], inputSamples[count - 1]), changed: &changed)
            samples = [samples[count - 1]]
            inputSamples = [inputSamples[count - 1]]
        }
        if settings.roundDynamics.hasTaper { try finalizeTaper(changed: &changed) }
        try publish(changed)
    }

