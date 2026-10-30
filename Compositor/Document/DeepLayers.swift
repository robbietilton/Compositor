import CoreGraphics
import CoreImage
import Foundation

/// 16-bit layers in 8-bit documents. A layer whose `ImportedImage` carries `deep` keeps its pixels at 16 bits a
/// channel; its `image` is a dithered 8-bit copy that the canvas, thumbnails and every tool keep using unchanged.
/// Operations that understand 16-bit pixels read `deep` and make a new one; any other operation makes a new
/// `ImportedImage` without it, which `keepLayerDepths` makes 16-bit again as the edit ends, so a layer stays at the depth
/// it was given until Convert to 8-Bit.
nonisolated enum DeepLayer {
    /// The one layout 16-bit pixels are kept in: sRGB, premultiplied RGBA, native-endian 16-bit, rows packed
    /// (`width × 8` bytes), top-left origin like `BrushRaster`. `hdr`: an HDR layer's instead, the same but half floats
    /// in extended sRGB, keeping light brighter than white (see `hdrSpace`).
    static func context(width: Int, height: Int, hdr: Bool = false) throws -> CGContext {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            | (hdr ? CGBitmapInfo.floatComponents.rawValue : 0)
        guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
            space: hdr ? hdrSpace : CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
            throw ExportError.render
        }
        result.translateBy(x: 0, y: CGFloat(height))
        result.scaleBy(x: 1, y: -1)
        return result
    }

    /// `image` drawn into the 16-bit layout, whatever it came in as.
    static func canonical(_ image: CGImage) throws -> CGContext {
        let context = try context(width: image.width, height: image.height)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }

    /// `image` at 16 bits in the standard layout, as a layer keeps it.
    static func image(_ image: CGImage) throws -> CGImage {
        guard let result = try canonical(image).makeImage() else { throw ExportError.render }
        return result
    }

    /// The layer's 8-bit copy: rounded with a fine noise rather than straight down, so gradients don't step.
    static func dithered(_ deep: CGImage) throws -> CGImage {
        let wide = try canonical(deep)
        let target = try BrushRaster.context(width: deep.width, height: deep.height, mask: false)
        guard let source = wide.data, let pixels = target.data else { throw ExportError.render }
        // Held to the end of the call: optimized, Swift may free a context right after its last use, its `data`.
        withExtendedLifetime(wide) {
            dither_quantize16(source.assumingMemoryBound(to: UInt16.self), pixels.assumingMemoryBound(to: UInt8.self),
                              deep.width, deep.height, target.bytesPerRow)
        }
        guard let result = target.makeImage() else { throw ExportError.render }
        return result
    }

    /// The whole layer at 16 bits (an HDR layer's in its own layout), or nil for an 8-bit layer. A painted layer's 16-bit pixels are its raster's base;
    /// the strokes go over them as 8-bit patches (fresh paint has no more to it), so most of it keeps its precision
    /// and a stroke costs no more than on any layer.
    static func flattened(_ asset: ImportedImage) throws -> CGImage? {
        guard let deep = asset.deep else { return nil }
        guard let raster = asset.raster, let base = raster.base else { return deep }
        let width = raster.width, height = raster.height, hdr = isHDR(deep)
        let whole = try context(width: width, height: height, hdr: hdr)
        BrushRaster.draw(deep, in: raster.baseRect, mask: false, context: whole)
        // Paint is wherever the layer's 8-bit pixels differ from its 8-bit base alone (`deep_take_painted`).
        let painted = try BrushRaster.copy(asset.image)
        let unpainted = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(base, in: raster.baseRect, mask: false, context: unpainted)
        guard painted.width == width, painted.height == height, let wholeData = whole.data, let paintedData = painted.data,
              let unpaintedData = unpainted.data else { throw ExportError.render }
        withExtendedLifetime((painted, unpainted)) {
            let paintedBytes = paintedData.assumingMemoryBound(to: UInt8.self), unpaintedBytes = unpaintedData.assumingMemoryBound(to: UInt8.self)
            if hdr {
                deep_take_painted_hdr(wholeData.assumingMemoryBound(to: UInt16.self), whole.bytesPerRow, paintedBytes, unpaintedBytes,
                                      painted.bytesPerRow, width, height)
            } else {
                deep_take_painted(wholeData.assumingMemoryBound(to: UInt16.self), whole.bytesPerRow, paintedBytes, unpaintedBytes,
                                  painted.bytesPerRow, width, height)
            }
        }
        guard let result = whole.makeImage() else { throw ExportError.render }
        return result
    }

    // MARK: HDR

    /// An HDR layer's pixels keep light brighter than white: half floats in extended sRGB (white is 1, highlights
    /// above it), premultiplied, top-left rows, 8 bytes a pixel as a 16-bit layer's. Edits keep them: Core Image and
    /// drawing work on them as they are; 8-bit operations through `run` and `lookup` see each highlight divided down to
    /// within white and multiply their result back (`deep_hdr_normalize`); Exposure works on them exactly (`exposure`).
    static let hdrSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    /// Whether `image` is HDR pixels (floats) rather than 16-bit ones.
    static func isHDR(_ image: CGImage) -> Bool { image.bitmapInfo.contains(.floatComponents) }

    /// `image` in the HDR layout, brighter-than-white values kept.
    static func hdr(_ image: CGImage) throws -> CGContext {
        let context = try context(width: image.width, height: image.height, hdr: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }

    /// An HDR image through an 8-bit operation that works on 16-bit pixels (`run`, `lookup`): each highlight divided
    /// down to within white for it, and its result multiplied back up (`deep_hdr_normalize`).
    static func normalizing(_ hdrImage: CGImage, through operation: (CGImage) throws -> CGImage) throws -> CGImage {
        let width = hdrImage.width, height = hdrImage.height
        let source = try hdr(hdrImage)
        let normal = try context(width: width, height: height)
        var scales = [Float](repeating: 1, count: width * height)
        guard let input = source.data, let normalData = normal.data else { throw ExportError.render }
        withExtendedLifetime(source) {
            deep_hdr_normalize(input.assumingMemoryBound(to: UInt16.self), source.bytesPerRow, normalData.assumingMemoryBound(to: UInt16.self),
                               normal.bytesPerRow, &scales, width, height)
        }
        guard let normalized = normal.makeImage() else { throw ExportError.render }
        let result = try canonical(try operation(normalized))
        guard result.width == width, result.height == height, let resultData = result.data else { throw ExportError.render }
        let out = try context(width: width, height: height, hdr: true)
        guard let outData = out.data else { throw ExportError.render }
        withExtendedLifetime(result) {
            deep_hdr_restore(resultData.assumingMemoryBound(to: UInt16.self), result.bytesPerRow, scales,
                             outData.assumingMemoryBound(to: UInt16.self), out.bytesPerRow, width, height)
        }
        guard let image = out.makeImage() else { throw ExportError.render }
        return image
    }

    /// A 16-bit or HDR layer whole, for the canvas to draw at its full depth, so an adjustment layer over it previews as
    /// its export will be (smooth, highlights kept): its pixels, or once it's painted, those with the paint laid on
    /// (`flattened`), made once per version of the layer and kept for the last few, as the canvas asks every frame. Nil
    /// for an 8-bit layer.
    static func canvasImage(_ asset: ImportedImage) -> CGImage? {
        guard let deep = asset.deep else { return nil }
        guard asset.raster != nil else { return deep }
        let key = ObjectIdentifier(asset.image)
        if let found = canvasLock.withLock({ canvasImages.first { $0.key == key }?.image }) { return found }
        guard let made = try? flattened(asset) else { return nil }
        canvasLock.withLock {
            // The source is held, so its identifier can't be reused by another image while the copy is kept.
            canvasImages.insert((key, asset.image, made), at: 0)
            if canvasImages.count > 6 { canvasImages.removeLast() }
        }
        return made
    }
    private static let canvasLock = NSLock()
    nonisolated(unsafe) private static var canvasImages: [(key: ObjectIdentifier, source: CGImage, image: CGImage)] = []

    /// An HDR layer's pixels at the size of `preview` (an 8-bit copy a panel previews from), for the panel to preview
    /// from instead, as OK works from them; nil for any other layer.
    static func hdrPreview(of asset: ImportedImage, matching preview: CGImage) throws -> CGImage? {
        guard asset.isHDR, let deep = try flattened(asset) else { return nil }
        guard deep.width != preview.width || deep.height != preview.height else { return deep }
        let context = try context(width: preview.width, height: preview.height, hdr: true)
        context.interpolationQuality = .high
        BrushRaster.draw(deep, in: CGRect(x: 0, y: 0, width: preview.width, height: preview.height), mask: false, context: context)
        return context.makeImage()
    }

    /// Exposure on HDR pixels, exactly: nothing clipped at white, so turning it down brings highlights into view.
    static func exposure(_ hdrImage: CGImage, _ settings: ExposureSettings) throws -> CGImage {
        let settings = settings.normalized
        let context = try hdr(hdrImage)
        guard let data = context.data else { throw ExportError.render }
        deep_hdr_exposure(data.assumingMemoryBound(to: UInt16.self), context.bytesPerRow, hdrImage.width, hdrImage.height,
                          Float(pow(2, settings.exposure)), Float(settings.offset), Float(1 / settings.gamma))
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// A layer asset for an image with more than 8 bits a channel: an HDR layer when it holds light brighter than
    /// white (a render or panorama in EXR or Radiance HDR), otherwise a 16-bit layer, as most such files are.
    static func wideAsset(_ image: CGImage, name: String) throws -> ImportedImage {
        guard image.bitmapInfo.contains(.floatComponents) else { return try asset(image, name: name) }
        let context = try hdr(image)
        guard let data = context.data else { throw ExportError.render }
        let peak = withExtendedLifetime(context) {
            deep_half_peak(data.assumingMemoryBound(to: UInt16.self), context.bytesPerRow, image.width, image.height)
        }
        // A thousandth over: a file brushing white through rounding isn't HDR.
        guard peak > 1.001, let pixels = context.makeImage() else { return try asset(try self.image(image), name: name) }
        // Shown, as everything is, from a dithered 8-bit copy: anything brighter than white shows as white.
        let shown = try dithered(try self.image(pixels))
        return ImportedImage(image: shown, thumbnail: try PixelAdjust.thumbnail(of: shown), name: name, deep: pixels)
    }

    /// A layer asset for 16-bit pixels: the 16-bit image, its dithered 8-bit copy and a thumbnail of it.
    static func asset(_ deep: CGImage, name: String) throws -> ImportedImage {
        // HDR pixels stay HDR while they still go brighter than white (an edit may have brought them all within it).
        if isHDR(deep) { return try wideAsset(deep, name: name) }
        let deep = try image(deep)
        let image = try dithered(deep)
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name, deep: deep)
    }

    /// An 8-bit edit's `result` for a layer that was 16-bit (or HDR) as `original`, kept at its depth: where `result`
    /// matches the layer's old 8-bit copy, nothing changed there and its 16-bit pixels stay (`deep_take_painted`), as
    /// outside Content-Aware Fill's selection; elsewhere the new 8-bit values are taken at 16 bits. A result of another
    /// size is all new, and taken whole.
    static func restored(_ result: CGImage, over original: ImportedImage, name: String) throws -> ImportedImage {
        guard let deep = try flattened(original) else { return ImportedImage(image: result, thumbnail: try PixelAdjust.thumbnail(of: result), name: name) }
        let width = result.width, height = result.height
        guard deep.width == width, deep.height == height, original.image.width == width, original.image.height == height else {
            return try asset(try image(result), name: name)
        }
        let hdr = isHDR(deep)
        let whole = try context(width: width, height: height, hdr: hdr)
        BrushRaster.draw(deep, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: whole)
        let painted = try BrushRaster.copy(result), unpainted = try BrushRaster.copy(original.image)
        guard let wholeData = whole.data, let paintedData = painted.data, let unpaintedData = unpainted.data else { throw ExportError.render }
        withExtendedLifetime((painted, unpainted)) {
            let paintedBytes = paintedData.assumingMemoryBound(to: UInt8.self), unpaintedBytes = unpaintedData.assumingMemoryBound(to: UInt8.self)
            if hdr {
                deep_take_painted_hdr(wholeData.assumingMemoryBound(to: UInt16.self), whole.bytesPerRow, paintedBytes, unpaintedBytes,
                                      painted.bytesPerRow, width, height)
            } else {
                deep_take_painted(wholeData.assumingMemoryBound(to: UInt16.self), whole.bytesPerRow, paintedBytes, unpaintedBytes,
                                  painted.bytesPerRow, width, height)
            }
        }
        guard let made = whole.makeImage() else { throw ExportError.render }
        return try asset(made, name: name)
    }

    /// Runs an 8-bit operation on a 16-bit image without losing its precision: on 8-bit values a little below its
    /// colors (rounded as dither rounds, `deep_split`) and on those one, two and four steps up, then reads the 16-bit
    /// result off between them (`deep_merge`). The operation must return an image the size it was given.
    /// `mixesChannels`, for an operation whose output channels each depend on all three inputs (Camera Raw's color
    /// sliders): each input channel is stepped on its own, ten runs, and every output channel adds up how each moves it.
    /// Read the other way, those came out banded.
    static func run(_ deep: CGImage, mixesChannels: Bool = false, through operation: (CGImage) throws -> CGImage) throws -> CGImage {
        if isHDR(deep) { return try normalizing(deep) { try run($0, mixesChannels: mixesChannels, through: operation) } }
        let width = deep.width, height = deep.height
        let source = try canonical(deep)
        guard let input = source.data else { throw ExportError.render }
        // (step, channel): -1 steps every channel together.
        let steps: [Int32] = [1, 2, 4]
        let channels: [Int32] = mixesChannels ? [0, 1, 2] : [-1]
        var splits: [(step: Int32, channel: Int32)] = [(0, -1)]
        for step in steps { for channel in channels { splits.append((step, channel)) } }
        let results = try splits.map { step, channel -> CGContext in
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            guard let bytes = context.data else { throw ExportError.render }
            deep_split(input.assumingMemoryBound(to: UInt16.self), source.bytesPerRow, bytes.assumingMemoryBound(to: UInt8.self),
                       context.bytesPerRow, width, height, step, channel)
            guard let image = context.makeImage() else { throw ExportError.render }
            let result = try operation(image)
            guard result.width == width, result.height == height else { throw ExportError.render }
            return try BrushRaster.copy(result)
        }
        let out = try context(width: width, height: height)
        let buffers = results.compactMap { $0.data.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) } }
        guard buffers.count == results.count, let outData = out.data else { throw ExportError.render }
        // Each step's three runs, red, green and blue stepped alone; or its one run, read for all three.
        let per = mixesChannels ? 3 : 1
        func runs(_ index: Int) -> [UnsafePointer<UInt8>?] {
            (0..<3).map { buffers[1 + index * per + (mixesChannels ? $0 : 0)] }
        }
        withExtendedLifetime((source, results)) {
            deep_merge(input.assumingMemoryBound(to: UInt16.self), source.bytesPerRow, buffers[0], runs(0), runs(1), runs(2),
                       results[0].bytesPerRow, outData.assumingMemoryBound(to: UInt16.self), out.bytesPerRow, width, height,
                       mixesChannels ? 1 : 0)
        }
        guard let result = out.makeImage() else { throw ExportError.render }
        return result
    }

    /// A color lookup (`cube`, `dimension`³ RGBA floats as Core Image's color cube) applied to 16-bit pixels, smoothly
    /// between its points. For operations whose channels mix (Hue/Saturation, Black & White, Color Balance, Gradient
    /// Map): `run` reads each channel's result off its own input, which they don't follow, and they came out banded.
    static func lookup(_ deep: CGImage, cube: Data, dimension: Int) throws -> CGImage {
        if isHDR(deep) { return try normalizing(deep) { try lookup($0, cube: cube, dimension: dimension) } }
        guard cube.count >= dimension * dimension * dimension * 4 * MemoryLayout<Float>.size else { throw ExportError.render }
        let context = try canonical(deep)
        guard let data = context.data else { throw ExportError.render }
        cube.withUnsafeBytes { raw in
            deep_cube_apply(data.assumingMemoryBound(to: UInt16.self), context.bytesPerRow, deep.width, deep.height,
                            raw.assumingMemoryBound(to: Float.self).baseAddress!, Int32(dimension))
        }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// Core Image working in full floats: its default, half floats, holds only about three bits more than 8, which a
    /// steep Levels after a blur would show as bands.
    static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                               .workingFormat: CIFormat.RGBAf])

    /// A Core Image result rendered at 16 bits, as `PixelAdjust.render` renders one at 8.
    /// `hdr`: at an HDR layer's half floats, keeping light brighter than white.
    static func render(_ image: CIImage, width: Int, height: Int, hdr: Bool = false) throws -> CGImage {
        guard let result = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                format: hdr ? .RGBAh : .RGBA16, colorSpace: hdr ? hdrSpace : CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw ExportError.render
        }
        return result
    }

    /// `deep` placed at `inside` on a clear 16-bit grid `size` large: a layer padded out for a blur to spread into.
    static func padded(_ deep: CGImage, to size: CGSize, inside: CGRect) throws -> CGImage {
        let context = try context(width: Int(size.width), height: Int(size.height), hdr: isHDR(deep))
        BrushRaster.draw(deep, in: inside, mask: false, context: context)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}

extension EditorSession {
    /// Whether the active layer can change between 8 and 16 bits a channel: one layer of pixels, or a blank one (not
    /// text, an adjustment or a folder, which have none of their own to keep).
    /// The layers Convert to 16-Bit / 8-Bit works on: the selected ones, and those in selected folders, that hold pixels
    /// it can convert. GIF frame overrides stay in their 8-bit grid; converting only the cached layer asset would be
    /// lost on playback.
    private var depthTargets: [ImageLayer] {
        guard canEditLayers, let document else { return [] }
        let selected = selectedLayerIDs.union(activeLayerID.map { [$0] } ?? [])
        func isSelected(_ layer: ImageLayer) -> Bool {
            var id: UUID? = layer.id, seen = 0
            while let current = id, seen < 64 {
                if selected.contains(current) { return true }
                id = document.layers.first { $0.id == current }?.parentID
                seen += 1
            }
            return false
        }
        return document.layers.filter {
            isSelected($0) && $0.gifAnimation == nil && $0.liveText == nil && $0.adjustment == nil && !$0.isGroup
        }
    }
    /// Whether one of them is 8-bit, blank or HDR, so Convert to 16-Bit would change it.
    var canConvertToSixteenBit: Bool { depthTargets.contains { $0.asset?.deep == nil || $0.asset?.isHDR == true } }
    /// Whether one of them is 16-bit or HDR, so Convert to 8-Bit would change it.
    var canConvertToEightBit: Bool { depthTargets.contains { $0.asset?.deep != nil } }

    /// Convert to 16-Bit / Convert to 8-Bit, for every selected layer, as one undo step. To 16 bits an 8-bit layer's
    /// pixels stay as they are and everything after keeps the extra precision; a blank layer gets clear 16-bit pixels over
    /// the canvas, to paint gradients on; an HDR layer is clipped to white and kept at 16 bits, more finely than half
    /// floats hold it. To 8 bits they're dithered down, halving the layer's memory and file size.
    func convertLayers(toSixteenBit: Bool) {
        guard let document else { return }
        var converted: [UUID: (asset: ImportedImage, transform: LayerTransform?)] = [:]
        do {
            for layer in depthTargets {
                if toSixteenBit {
                    if let asset = layer.asset, asset.isHDR {
                        guard let deep = try DeepLayer.flattened(asset) else { continue }
                        converted[layer.id] = (try DeepLayer.asset(try DeepLayer.image(deep), name: asset.name), nil)
                    } else if let asset = layer.asset {
                        guard asset.deep == nil else { continue }
                        converted[layer.id] = (ImportedImage(image: asset.image, thumbnail: asset.thumbnail, name: asset.name,
                                                             deep: try DeepLayer.image(asset.image)), nil)
                    } else {
                        let clear = try DeepLayer.context(width: document.width, height: document.height)
                        guard let deep = clear.makeImage() else { continue }
                        converted[layer.id] = (try DeepLayer.asset(deep, name: layer.name), LayerTransform(origin: .zero, size: document.size))
                    }
                } else if let asset = layer.asset, let deep = try DeepLayer.flattened(asset) {
                    let image = try DeepLayer.dithered(deep)
                    converted[layer.id] = (ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: asset.name), nil)
                }
            }
        } catch { brushError = error.localizedDescription; return }
        guard !converted.isEmpty else { return }
        let layers = document.layers.map { layer in
            guard let change = converted[layer.id] else { return layer }
            var layer = layer
            layer.asset = change.asset
            if let transform = change.transform { layer.transform = transform }
            return layer
        }
        beginEdit(toSixteenBit ? "Convert to 16-Bit" : "Convert to 8-Bit")
        self.document?.layers = layers
        // The one edit that makes a 16-bit layer 8-bit on purpose.
        convertsToEightBit = !toSixteenBit
        endEdit()
        convertsToEightBit = false
    }

    /// Keeps a layer at the depth it was given: an edit that left a 16-bit or HDR layer `before` with only 8-bit pixels
    /// (Content-Aware Fill, Remove Background, Dither, an 8-bit tool) has its result made 16-bit again, the layer's
    /// 16-bit pixels kept wherever the edit didn't change it. Only Convert to 8-Bit makes a layer 8-bit.
    func keepLayerDepths(since before: CanvasDocument) {
        guard !convertsToEightBit, let document else { return }
        let deep = Dictionary(before.layers.compactMap { layer in layer.asset.flatMap { $0.deep != nil ? (layer.id, $0) : nil } },
                              uniquingKeysWith: { first, _ in first })
        guard !deep.isEmpty else { return }
        var restored: [UUID: ImportedImage] = [:]
        for layer in document.layers where layer.gifAnimation == nil && layer.liveText == nil {
            guard let original = deep[layer.id], let asset = layer.asset, asset.deep == nil, asset.image !== original.image,
                  let made = try? DeepLayer.restored(asset.image, over: original, name: asset.name) else { continue }
            restored[layer.id] = made
        }
        guard !restored.isEmpty else { return }
        self.document?.layers = document.layers.map { layer in
            guard let asset = restored[layer.id] else { return layer }
            var layer = layer
            layer.asset = asset
            return layer
        }
    }
}
