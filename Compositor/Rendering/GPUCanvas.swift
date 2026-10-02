#if os(macOS)
import AppKit
#endif
import CoreImage
import Metal
import QuartzCore

/// The canvas composited on the GPU. Core Graphics composites every layer on the CPU, about 5 ms for each full-size
/// layer on a Retina screen, on every frame of a drag, pan or zoom; here the layers stay on the GPU as textures and a
/// frame only places them again.
///
/// Everything is laid out in pixel coordinates with y pointing down, as the pixels sit in a texture: an image's top
/// row is its row 0, and the frame's row 0 is the top of the view. Blending happens in sRGB, not linear light, as it
/// does on the canvas and in Photoshop.
@MainActor final class GPUCanvasRenderer {
    static let shared: GPUCanvasRenderer? = GPUCanvasRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct Key: Hashable {
        let id: ObjectIdentifier
        let level: Int
    }
    private struct Entry {
        /// Held so the identifier can't be reused by another object while the texture is kept.
        let source: AnyObject
        let image: CIImage
        var used: Int
        /// Frames it's kept after its last use.
        var keep: Int
    }
    private var textures: [Key: Entry] = [:]
    private var frame = 0
    /// Textures made, and the time it took on the main thread. A reduction's time includes waiting for the GPU work
    /// queued before it; a painted layer's is the time to queue its own.
    private struct TextureWork {
        var frames = 0, images = 0, masks = 0, converted = 0, pixels = 0, reductions = 0, rasters = 0
        var copying = Duration.zero, writing = Duration.zero, reducing = Duration.zero, assembling = Duration.zero
        var isEmpty: Bool { images + masks + reductions + rasters == 0 }
        var total: Duration { copying + writing + reducing + assembling }
        var detail: String {
            var parts: [String] = []
            if images + masks > 0 {
                let made = Timing.counted(images, "image") + (masks == 0 ? "" : " and " + Timing.counted(masks, "mask"))
                parts.append("\(made) of \(Timing.megapixels(pixels)), \(converted) converted: "
                    + "copying \(Timing.milliseconds(copying)), writing \(Timing.milliseconds(writing))")
            }
            if reductions > 0 { parts.append("\(Timing.counted(reductions, "reduction")) \(Timing.milliseconds(reducing))") }
            if rasters > 0 { parts.append("\(Timing.counted(rasters, "painted layer")) \(Timing.milliseconds(assembling))") }
            return (frames > 1 ? "over \(frames) frames, " : "") + parts.joined(separator: "; ")
        }
        mutating func add(_ other: TextureWork) {
            frames += other.frames; images += other.images; masks += other.masks; converted += other.converted
            pixels += other.pixels; reductions += other.reductions; rasters += other.rasters
            copying += other.copying; writing += other.writing; reducing += other.reducing; assembling += other.assembling
        }
    }
    /// What the frame being drawn has made, and what frames before it made that hasn't been said yet.
    private var work = TextureWork(), held = TextureWork()
    private var lastWorkLine: ContinuousClock.Instant?, lastWorkFrame: ContinuousClock.Instant?
    /// Textures not used for this many frames are let go.
    private let keepFrames = 90

    /// A stroke in progress as one texture: the layer's old pixels (or old mask) with the stroke's tiles written in as
    /// they change, so a frame uploads only the tiles the last few dabs touched.
    private final class StrokeTexture {
        let texture: MTLTexture
        let image: CIImage
        var written: [CGPoint: ObjectIdentifier] = [:]
        init(texture: MTLTexture, image: CIImage) {
            self.texture = texture
            self.image = image
        }
    }
    private var strokes: [ObjectIdentifier: (stroke: BrushStroke, texture: StrokeTexture, used: Int)] = [:]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: space, .cacheIntermediates: false])
        // Once the canvas stops redrawing, what its last frame didn't use goes; frames alone would never count past it.
        idle = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.frame == self.lastIdleFrame { self.release(keepingLastFrame: true) }
                self.lastIdleFrame = self.frame
                self.sayHeldTextureWork()
            }
        }
        // Short of memory, the system says so: what the last frame didn't use goes, and everything when it's critical —
        // the next frame uploads what it needs again.
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.release(keepingLastFrame: !self.pressure.data.contains(.critical))
            }
        }
        pressure.resume()
    }
    private var idle: Timer?
    private var lastIdleFrame = -1
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    private func say(_ made: inout TextureWork) {
        guard !made.isEmpty else { return }
        Timing.report("Textures", took: made.total, made.detail)
        made = TextureWork()
        lastWorkLine = .now
    }

    /// What frames held back, once none has made textures for a second; with what draws that were never presented made.
    private func sayHeldTextureWork() {
        guard lastWorkFrame.map({ ContinuousClock.now - $0 >= .seconds(1) }) ?? true else { return }
        held.add(work)
        work = TextureWork()
        say(&held)
    }

    /// Lets go of textures: all but the ones the last frame drew from, or all of them.
    private func release(keepingLastFrame: Bool) {
        let last = frame - 1
        textures = keepingLastFrame ? textures.filter { $0.value.used >= last } : [:]
        strokes = keepingLastFrame ? strokes.filter { $0.value.used >= last } : [:]
    }

    /// `image` as a texture, `level` halvings smaller (sharp reductions for zooming out, as `DownsampleCache` makes on
    /// the CPU). A mask comes back with its values in the red channel. A `transient` image — one that's replaced every
    /// frame, like a Smudge stroke's — is kept only for the frame it's drawn in, and reduced as it's drawn.
    func image(_ image: CGImage, level: Int = 0, mask: Bool = false, transient: Bool = false) -> CIImage? {
        texture(image, level: level, mask: mask, transient: transient, drawing: true)
    }

    /// The texture for one level of `image`. Each reduction is made from the one a level up (sharp halvings, as
    /// `DownsampleCache` makes them); one used only to make a smaller one — the full size, zoomed out — goes at the end of
    /// the frame, as nothing draws from it. On a large document seen whole, that full size was most of the memory.
    private func texture(_ image: CGImage, level: Int, mask: Bool, transient: Bool, drawing: Bool) -> CIImage? {
        let key = Key(id: ObjectIdentifier(image), level: transient ? 0 : level)
        let keep = transient ? 1 : drawing || level > 0 ? keepFrames : 0
        let found: CIImage?
        if var entry = textures[key] {
            entry.used = frame
            entry.keep = max(entry.keep, keep)
            textures[key] = entry
            found = entry.image
        } else {
            let made: CIImage?
            if level == 0 || transient {
                made = upload(image, mask: mask, transient: transient)
            } else if let larger = texture(image, level: level - 1, mask: mask, transient: false, drawing: false) {
                made = reduce(larger, from: Self.size(image.width, image.height, level: level - 1),
                              to: Self.size(image.width, image.height, level: level), mask: mask)
            } else { made = nil }
            guard let made else { return nil }
            textures[key] = Entry(source: image, image: made, used: frame, keep: keep)
            found = made
        }
        guard transient, level > 0, let found else { return found }
        return Self.reduced(found, width: image.width, height: image.height, level: level)
    }

    /// The levels of `image` held as textures, for checking what the cache keeps.
    func cachedLevels(of image: CGImage) -> [Int] {
        textures.keys.filter { $0.id == ObjectIdentifier(image) }.map(\.level).sorted()
    }

    /// A grid `level` halvings smaller, each rounded up as `DownsampleCache` rounds them.
    static func size(_ width: Int, _ height: Int, level: Int) -> CGSize {
        CGSize(width: max(1, (width + (1 << level) - 1) >> level), height: max(1, (height + (1 << level) - 1) >> level))
    }

    /// `stroke`'s grid as it stands: the layer's old pixels, or for a mask stroke its old mask (revealing past it), with
    /// every tile the stroke has changed written over them.
    func image(_ stroke: BrushStroke, base: CIImage?) -> CIImage? {
        let id = ObjectIdentifier(stroke)
        let entry: StrokeTexture
        if let known = strokes[id] {
            entry = known.texture
        } else {
            guard let texture = texture(width: stroke.width, height: stroke.height, mask: stroke.isMask),
                  let image = wrap(texture, mask: stroke.isMask), let buffer = queue.makeCommandBuffer() else { return nil }
            let grid = CGRect(x: 0, y: 0, width: stroke.width, height: stroke.height)
            // Transparent past the old pixels; a mask is its background past its old values (see LayerMask.background),
            // as the stroke's own tiles start and as it's committed. White there showed a hiding mask's edges revealing.
            let edge = stroke.maskBackground
            var start = (stroke.isMask ? CIImage(color: CIColor(red: edge, green: edge, blue: edge)) : CIImage.clear).cropped(to: grid)
            if let base {
                let placed = base.clampedToExtent().transformed(by: CGAffineTransform(
                    scaleX: stroke.sourceRect.width / base.extent.width, y: stroke.sourceRect.height / base.extent.height)
                    .concatenating(CGAffineTransform(translationX: stroke.sourceRect.minX, y: stroke.sourceRect.minY)))
                start = placed.cropped(to: stroke.sourceRect).composited(over: start)
            }
            context.render(start, to: texture, commandBuffer: buffer, bounds: grid, colorSpace: space)
            buffer.commit()
            buffer.waitUntilCompleted()
            entry = StrokeTexture(texture: texture, image: image)
        }
        strokes[id] = (stroke, entry, frame)
        let writes = TileWrites(renderer: self, into: entry.texture, mask: stroke.isMask)
        for patch in stroke.patches {
            let key = patch.rect.origin, identity = ObjectIdentifier(patch.image)
            guard entry.written[key] != identity else { continue }
            if writes.place(patch.image, at: patch.rect) { entry.written[key] = identity }
        }
        writes.commit()
        return entry.image
    }

    /// Tiles written into a texture the GPU has drawn into: each is uploaded to a small texture of its own and copied into
    /// place by the GPU, in order with everything else it does to that texture. Written straight into the texture's
    /// memory instead, a tile isn't seen on every GPU — a virtual machine's keeps its own copy, and parts of the texture
    /// came out empty.
    private final class TileWrites {
        let renderer: GPUCanvasRenderer
        let texture: MTLTexture
        let mask: Bool
        private var buffer: MTLCommandBuffer?
        private var blit: MTLBlitCommandEncoder?
        init(renderer: GPUCanvasRenderer, into texture: MTLTexture, mask: Bool) {
            self.renderer = renderer
            self.texture = texture
            self.mask = mask
        }
        /// Writes `image`, which covers `rect` of the texture, clipped to the texture. False when there was nothing to write.
        @discardableResult
        func place(_ image: CGImage, at rect: CGRect) -> Bool {
            let bounds = rect.integral.intersection(CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
            guard !bounds.isEmpty, image.width == Int(rect.width.rounded()), image.height == Int(rect.height.rounded()),
                  let pixels = try? (mask ? GPUCanvasRenderer.grayCopy(image) : BrushRaster.copy(image)), let data = pixels.data
            else { return false }
            let w = Int(bounds.width), h = Int(bounds.height)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared
            guard let staging = renderer.device.makeTexture(descriptor: descriptor) else { return false }
            let bytes = mask ? 1 : 4
            let offset = Int(bounds.minY - rect.minY.rounded()) * pixels.bytesPerRow + Int(bounds.minX - rect.minX.rounded()) * bytes
            staging.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data + offset, bytesPerRow: pixels.bytesPerRow)
            if blit == nil {
                buffer = renderer.queue.makeCommandBuffer()
                blit = buffer?.makeBlitCommandEncoder()
            }
            blit?.copy(from: staging, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                       sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                       destinationOrigin: MTLOrigin(x: Int(bounds.minX), y: Int(bounds.minY), z: 0))
            return true
        }
        /// Sends the copies. Frames drawn from the texture come after them on the same queue.
        func commit() {
            blit?.endEncoding()
            buffer?.commit()
        }
    }

    /// A painted layer's tiles put together into one texture, redone only when the raster is replaced.
    func image(_ raster: RasterSnapshot, level: Int = 0) -> CIImage? { texture(raster, level: level, drawing: true) }

    private func texture(_ raster: RasterSnapshot, level: Int, drawing: Bool) -> CIImage? {
        let key = Key(id: ObjectIdentifier(raster), level: level)
        let keep = drawing || level > 0 ? keepFrames : 0
        if var entry = textures[key] {
            entry.used = frame
            entry.keep = max(entry.keep, keep)
            textures[key] = entry
            return entry.image
        }
        let made: CIImage?
        if level == 0 {
            made = assemble(raster)
        } else if let larger = texture(raster, level: level - 1, drawing: false) {
            made = reduce(larger, from: Self.size(raster.width, raster.height, level: level - 1),
                          to: Self.size(raster.width, raster.height, level: level), mask: raster.isMask)
        } else { made = nil }
        guard let made else { return nil }
        textures[key] = Entry(source: raster, image: made, used: frame, keep: keep)
        return made
    }

    /// Lets go of textures no frame has used for a while, and says what making textures took. The first frame to make
    /// any after a quiet second gets a line of its own, so one that stalls on them shows; frames that keep making
    /// them, as a drag can, are summed up at most once a second, and what's left once they stop, a few seconds later.
    func endFrame() {
        if !work.isEmpty {
            let now = ContinuousClock.now
            work.frames = 1
            if lastWorkFrame.map({ now - $0 >= .seconds(1) }) ?? true {
                say(&held)
                say(&work)
            } else {
                held.add(work)
                work = TextureWork()
                if lastWorkLine.map({ now - $0 >= .seconds(1) }) ?? true { say(&held) }
            }
            lastWorkFrame = now
        }
        frame += 1
        textures = textures.filter { $0.value.used >= frame - $0.value.keep }
        strokes = strokes.filter { $0.value.used >= frame - keepFrames }
    }

    private func texture(width: Int, height: Int, mask: Bool) -> MTLTexture? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mask ? .r8Unorm : .rgba8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func wrap(_ texture: MTLTexture, mask: Bool) -> CIImage? {
        CIImage(mtlTexture: texture, options: [.colorSpace: mask ? NSNull() : space])
    }

    /// The image's own bytes, copied straight in: sRGB, premultiplied, top row first — or for a mask, its gray values.
    /// An image that isn't laid out that way is drawn into that layout first. A `transient` image, replaced every
    /// frame, isn't counted in the lines about textures.
    private func upload(_ image: CGImage, mask: Bool, transient: Bool) -> CIImage? {
        var copying = Duration.zero, writing = Duration.zero
        guard let texture = texture(width: image.width, height: image.height, mask: mask),
              let pixels = try? Timing.step("Texture copy", adding: &copying, { try mask ? Self.grayCopy(image) : BrushRaster.copy(image) }),
              let data = pixels.data else { return nil }
        Timing.step("Texture write", adding: &writing) {
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: pixels.bytesPerRow)
        }
        guard let made = wrap(texture, mask: mask) else { return nil }
        if !transient {
            if mask { work.masks += 1 } else { work.images += 1 }
            if !mask, !BrushRaster.copiesStraight(image) { work.converted += 1 }
            work.pixels += image.width * image.height
            work.copying += copying
            work.writing += writing
        }
        return made
    }

    static func grayCopy(_ image: CGImage) throws -> CGContext {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }

    private func assemble(_ raster: RasterSnapshot) -> CIImage? {
        var assembling = Duration.zero
        let made = Timing.step("Raster assembly", adding: &assembling) { () -> CIImage? in
            guard let texture = texture(width: raster.width, height: raster.height, mask: raster.isMask) else { return nil }
            // Transparent (or a mask's fill) everywhere first, then the base and every tile in its place: tiles replace
            // what's under them, transparent pixels included.
            let clear = raster.isMask ? CIImage(color: CIColor(red: raster.fill, green: raster.fill, blue: raster.fill)) : CIImage.clear
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            context.render(clear, to: texture, commandBuffer: buffer,
                           bounds: CGRect(x: 0, y: 0, width: raster.width, height: raster.height), colorSpace: space)
            buffer.commit()
            let writes = TileWrites(renderer: self, into: texture, mask: raster.isMask)
            if let base = raster.base { writes.place(base, at: raster.baseRect) }
            for patch in raster.patches { writes.place(patch.image, at: patch.rect) }
            writes.commit()
            return wrap(texture, mask: raster.isMask)
        }
        if made != nil {
            work.rasters += 1
            work.assembling += assembling
        }
        return made
    }

    /// `full` (`width` × `height`) `level` halvings smaller, sharply, rounded up like `DownsampleCache`'s — computed as
    /// it's drawn, for images that change from frame to frame.
    static func reduced(_ full: CIImage, width: Int, height: Int, level: Int) -> CIImage {
        let w = max(1, (width + (1 << level) - 1) >> level), h = max(1, (height + (1 << level) - 1) >> level)
        let sx = CGFloat(w) / CGFloat(width), sy = CGFloat(h) / CGFloat(height)
        return full.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// `larger` (`from` in size) sharply reduced to `to`, kept as a texture of its own.
    private func reduce(_ larger: CIImage, from: CGSize, to: CGSize, mask: Bool) -> CIImage? {
        var reducing = Duration.zero
        let made = Timing.step("Texture reduction", adding: &reducing) { () -> CIImage? in
            let w = Int(to.width), h = Int(to.height)
            let sx = to.width / from.width, sy = to.height / from.height
            let reduced = larger.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            guard let texture = texture(width: w, height: h, mask: mask), let buffer = queue.makeCommandBuffer() else { return nil }
            // A mask's values carry no color space; rendered in the working space, they're written as they are.
            context.render(reduced, to: texture, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           colorSpace: space)
            buffer.commit()
            buffer.waitUntilCompleted()
            return wrap(texture, mask: mask)
        }
        if made != nil {
            work.reductions += 1
            work.reducing += reducing
        }
        return made
    }

    /// Draws `image` into `layer`'s next drawable, in step with the Core Animation transaction it's drawn in, so it
    /// lands on the same frame as the overlays above it. `drawn` runs once the GPU has drawn it, on a thread of Metal's.
    func present(_ image: CIImage, in layer: CAMetalLayer, drawn: [@Sendable () -> Void] = []) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let size = layer.drawableSize
        // Core Image writes a texture that can be rendered to bottom row first (a plain one, top row first), so the
        // frame is turned over to land top row first.
        let upright = drawable.texture.usage.contains(.renderTarget)
            ? image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)) : image
        context.render(upright, to: drawable.texture, commandBuffer: buffer,
                       bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), colorSpace: space)
        if !drawn.isEmpty { buffer.addCompletedHandler { _ in drawn.forEach { $0() } } }
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
        endFrame()
    }
}

#if os(macOS)
/// The GPU canvas's surface: a Metal layer under the canvas's overlays, shown while the GPU draws the canvas.
final class MetalCanvasView: NSView {
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = GPUCanvasRenderer.shared?.device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Core Image writes the frame with a compute pass.
        layer.framebufferOnly = false
        layer.presentsWithTransaction = true
        layer.isOpaque = true
        return layer
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // Clicks go to the canvas behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sizes the drawable to the view in screen pixels.
    func fit(scale: CGFloat) {
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}
#endif

/// How one layer's pixels land in the frame.
@MainActor struct GPUPlacement {
    /// Document pixels to frame pixels (y down).
    let mapping: CGAffineTransform
    /// Frame pixels per document pixel.
    let scale: CGFloat
    let renderer: GPUCanvasRenderer

    /// `source` (an image or a painted raster, `width` × `height` pixels) placed where `transform` puts it. Large
    /// reductions draw from a sharp smaller copy; pixel for pixel, or with Nearest sampling, pixels are copied.
    func place(width: Int, height: Int, transform: LayerTransform, mask: Bool = false,
               source: (Int) -> CIImage?) -> CIImage? {
        guard width > 0, height > 0 else { return nil }
        let factor = transform.size.width * scale / CGFloat(width)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: factor)
        guard let image = source(level) else { return nil }
        // The grid `level` halvings down, rounded up as the reductions are — known here, since an image that's
        // transparent at its edges can have a smaller extent than its grid.
        let reduced = CGSize(width: max(1, (width + (1 << level) - 1) >> level), height: max(1, (height + (1 << level) - 1) >> level))
        let toFull = CGAffineTransform(scaleX: CGFloat(width) / reduced.width, y: CGFloat(height) / reduced.height)
        let toFrame = BrushRaster.pixelToDocument(transform, width: width, height: height).concatenating(mapping)
        let upright = transform.radians == 0 && abs(abs(factor) - 1) < 0.001 && level == 0
        let sampled = transform.sampling == .nearest || upright ? image.samplingNearest() : image
        // Sampled up to its edge with its own edge pixels, and then cut to the layer's outline, as Core Graphics draws an
        // image into a rectangle. Smoothed against the transparency past its edge instead, a small image stretched over
        // a layer — a new mask is a single pixel — would come out faded all over.
        let placed = sampled.clampedToExtent().transformed(by: toFull.concatenating(toFrame))
        let grid = CGRect(x: 0, y: 0, width: width, height: height)
        if toFrame.b == 0, toFrame.c == 0 { return placed.cropped(to: grid.applying(toFrame)) }
        // Turned, the outline is drawn at about screen size before it's turned, so its edges soften over one screen pixel
        // whatever the image's size.
        let sx = max(1, hypot(toFrame.a, toFrame.b)), sy = max(1, hypot(toFrame.c, toFrame.d))
        let outline = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(width) * sx, height: CGFloat(height) * sy))
            .transformed(by: CGAffineTransform(scaleX: 1 / sx, y: 1 / sy).concatenating(toFrame))
        return GPUBlend.masked(placed, by: outline)
    }

    /// `image`, shown through `transform`, taken in perspective so its corners land on `corners` (document points, handle
    /// order) — `DistortWarp.warp` for a convex shape, done here at full size rather than on the CPU for every move.
    func warp(_ image: CGImage, transform: LayerTransform, corners: [CGPoint], mask: Bool = false) -> CIImage? {
        guard DistortWarp.isConvex(corners) else { return nil }
        let target = DistortWarp.imageCorners(corners.map { $0.applying(mapping) }, flipX: transform.flipX, flipY: transform.flipY)
        let xs = [target.topLeft.x, target.topRight.x, target.bottomRight.x, target.bottomLeft.x]
        let ys = [target.topLeft.y, target.topRight.y, target.bottomRight.y, target.bottomLeft.y]
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let level = transform.sampling == .nearest ? 0 : DownsampleCache.level(for: span / CGFloat(max(image.width, image.height)))
        guard let source = renderer.image(image, level: level, mask: mask) else { return nil }
        // Core Image's top edge is the image's last row here, where y counts down the rows.
        func taken(_ image: CIImage, extent: CGRect) -> CIImage {
            image.applyingFilter("CIPerspectiveTransformWithExtent", parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputTopLeft": CIVector(cgPoint: target.bottomLeft), "inputTopRight": CIVector(cgPoint: target.bottomRight),
                "inputBottomRight": CIVector(cgPoint: target.topRight), "inputBottomLeft": CIVector(cgPoint: target.topLeft)])
        }
        let size = CGSize(width: max(1, (image.width + (1 << level) - 1) >> level), height: max(1, (image.height + (1 << level) - 1) >> level))
        let sampled = transform.sampling == .nearest ? source.samplingNearest() : source
        // Carried past its edges and cut to the shape, drawn at screen size (see `place`).
        let outlineSide = max(span, 1)
        let outline = taken(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: outlineSide, height: outlineSide)),
                            extent: CGRect(x: 0, y: 0, width: outlineSide, height: outlineSide))
        return GPUBlend.masked(taken(sampled.clampedToExtent(), extent: CGRect(origin: .zero, size: size)), by: outline)
    }

    func place(_ image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        place(width: image.width, height: image.height, transform: transform, mask: mask) {
            renderer.image(image, level: $0, mask: mask)
        }
    }

    /// An image that changes from frame to frame (`width` × `height`, at its extent's origin), placed like `place`, with
    /// its reductions computed as it's drawn.
    func place(live image: CIImage, width: Int, height: Int, transform: LayerTransform) -> CIImage? {
        // Transparent to the grid's edge, so the edge pixels carried past it are the grid's own.
        let grid = CGRect(x: 0, y: 0, width: width, height: height)
        let full = image.cropped(to: grid).composited(over: CIImage.clear.cropped(to: grid))
        return place(width: width, height: height, transform: transform) { level in
            level == 0 ? full : GPUCanvasRenderer.reduced(full, width: width, height: height, level: level)
        }
    }

    func place(transient image: CGImage, transform: LayerTransform, mask: Bool = false) -> CIImage? {
        place(width: image.width, height: image.height, transform: transform, mask: mask) {
            renderer.image(image, level: $0, mask: mask, transient: true)
        }
    }

    func place(_ raster: RasterSnapshot, transform: LayerTransform) -> CIImage? {
        place(width: raster.width, height: raster.height, transform: transform, mask: raster.isMask) {
            renderer.image(raster, level: $0)
        }
    }
}

nonisolated enum GPUBlend {
    /// `top` composited over `bottom` in `mode`.
    static func blend(_ top: CIImage, over bottom: CIImage, mode: LayerBlendMode) -> CIImage {
        guard let name = filterName(mode) else { return top.composited(over: bottom) }
        return top.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: bottom])
    }

    static func filterName(_ mode: LayerBlendMode) -> String? {
        if let name = mode.coreImageFilter { return name }
        switch mode {
        case .normal: return nil
        case .darken: return "CIDarkenBlendMode"
        case .multiply: return "CIMultiplyBlendMode"
        case .lighten: return "CILightenBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        case .hardLight: return "CIHardLightBlendMode"
        case .difference: return "CIDifferenceBlendMode"
        case .exclusion: return "CIExclusionBlendMode"
        case .hue: return "CIHueBlendMode"
        case .saturation: return "CISaturationBlendMode"
        case .color: return "CIColorBlendMode"
        case .luminosity: return "CILuminosityBlendMode"
        default: return nil
        }
    }

    /// `image` shown only where `mask` (values in red) is on, and nothing elsewhere — past the mask's edges too, as a
    /// Core Graphics clip to a mask does.
    static func masked(_ image: CIImage, by mask: CIImage) -> CIImage {
        image.applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(),
                                                                 kCIInputMaskImageKey: mask])
    }

    /// `image` at `opacity`.
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }
}

nonisolated enum GPUAdjustment {
    /// `image` adjusted, laid out in frame pixels: `scale` frame pixels per document pixel, and `mapping` from document
    /// pixels to the frame (for Grain, whose pattern belongs to the document).
    static func apply(_ adjustment: LayerAdjustment, to image: CIImage, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        switch adjustment.kind {
        case .levels:
            guard !adjustment.levels.isIdentity else { return image }
            // Enough entries that stepping between them stays well under one 8-bit level.
            let size = 1024, step = Double(size - 1)
            let curve = (0..<size).flatMap { index in
                [LevelsChannel.red, .green, .blue].map { Float(adjustment.levels.apply(Double(index) / step, channel: $0)) }
            }
            return image.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curve.withUnsafeBufferPointer { Data(buffer: $0) },
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        case .hsv:
            return image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": HueSaturationFilter.dimension,
                "inputCubeData": HueSaturationFilter.cube(adjustment.resolvedHSV),
            ])
        case .curves, .blackWhite, .colorBalance, .exposure, .gradientMap, .invert:
            guard let cube = cube(for: adjustment) else { return nil }
            return image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cube])
        case .gaussianBlur:
            // Not clamped, as on the Core Graphics canvas: the blur spreads past the pixels' edges.
            return image.applyingGaussianBlur(sigma: adjustment.gaussianRadius * scale)
        case .motionBlur:
            // Core Image's angle turns counterclockwise with y up; the frame's y points down.
            return image.applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: adjustment.resolvedMotionDistance * scale * PixelFilter.motionRadiusPerPixel,
                kCIInputAngleKey: -adjustment.resolvedMotionAngle * .pi / 180,
            ])
        case .addNoise:
            return GPUNoise.addNoise(to: image, mapping: mapping, amount: Float(min(400, max(0.1, adjustment.resolvedNoiseAmount))),
                                     gaussian: adjustment.resolvedNoiseGaussian,
                                     monochromatic: adjustment.resolvedNoiseMonochromatic, seed: adjustment.resolvedNoiseSeed)
        case .grain:
            return GPUNoise.addGrain(to: image, grain: adjustment.grain, scale: scale, mapping: mapping)
        }
    }

    // MARK: Color lookups

    /// Points per axis of the lookups for adjustments that change each color on its own, as Hue/Saturation's.
    static let dimension = 33
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [(adjustment: LayerAdjustment, data: Data)] = []

    /// A lookup for an adjustment that changes each color on its own, made by running the adjustment itself over every
    /// point of the lattice — so the GPU canvas shows what export makes, with nothing worked out twice.
    static func cube(for adjustment: LayerAdjustment) -> Data? {
        if let known = lock.withLock({ cubes.first { $0.adjustment == adjustment }?.data }) { return known }
        let n = dimension, width = n * n
        guard let lattice = try? BrushRaster.context(width: width, height: n, mask: false), let pixels = lattice.data else { return nil }
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        func level(_ i: Int) -> UInt8 { UInt8((Double(i) * 255 / Double(n - 1)).rounded()) }
        // Red along each row, green across blocks of rows' columns, blue down the rows: the order the lookup reads.
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = b * lattice.bytesPerRow + (g * n + r) * 4
            bytes[i] = level(r); bytes[i + 1] = level(g); bytes[i + 2] = level(b); bytes[i + 3] = 255
        } } }
        guard let source = lattice.makeImage(), let adjusted = try? adjustment.apply(source),
              let out = try? BrushRaster.copy(adjusted), let result = out.data else { return nil }
        let values = result.assumingMemoryBound(to: UInt8.self)
        var floats = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = b * out.bytesPerRow + (g * n + r) * 4, o = ((b * n + g) * n + r) * 4
            floats[o] = Float(values[i]) / 255; floats[o + 1] = Float(values[i + 1]) / 255; floats[o + 2] = Float(values[i + 2]) / 255
        } } }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock {
            cubes.removeAll { $0.adjustment == adjustment }
            cubes.insert((adjustment, data), at: 0)
            if cubes.count > 16 { cubes.removeLast() }
        }
        return data
    }
}
