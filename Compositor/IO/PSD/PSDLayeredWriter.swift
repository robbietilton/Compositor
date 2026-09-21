import Foundation
import CoreGraphics
import Accelerate

/// Writes a whole layered PSD (v1, RGB, 8-bit): header, image resources, a Layer & Mask
/// section built from the compositor's layer tree (bottom-up records, RLE channels, groups
/// as lsct seal/header pairs — folders here blend pass-through, so headers carry the `pass`
/// key —, masks as -2 channels, clipping as PSD clipping flags), and the flattened composite
/// the renderer produced.
nonisolated enum PSDLayeredWriter {
    static func write(_ snapshot: ProjectSnapshot, composite: CGImage, resolution: Double) throws -> Data {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...30_000).contains(width), (1...30_000).contains(height),
              width * height <= 100_000_000 else { throw ExportError.tooLarge }
        for layer in snapshot.manifest.layers {
            guard layer.imageFile == nil || snapshot.images[layer.id] != nil,
                  layer.maskFile == nil || snapshot.masks[layer.id] != nil else { throw ProjectError.missingImage }
        }
        var file = PSDWriter()
        file.append(PSDFormat.signature)
        file.u16(1)      // version: PSD (not PSB)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(4)      // composite channels: RGBA
        file.u32(UInt32(height))
        file.u32(UInt32(width))
        file.u16(8)      // depth
        file.u16(3)      // RGB
        file.u32(0)      // color mode data
        appendResources(&file, resolution: resolution)
        try appendLayerAndMask(&file, snapshot: snapshot)
        try appendComposite(&file, image: composite)
        return Data(file.bytes)
    }

    /// Image resources: just ResolutionInfo (1005), so the document keeps its DPI.
    private static func appendResources(_ file: inout PSDWriter, resolution: Double) {
        var section = PSDWriter()
        section.append(PSDFormat.blockSignature)
        section.u16(1005)
        section.append([0, 0])             // empty pascal name, padded to even
        var data = PSDWriter()
        let fixed = UInt32(clamping: Int((resolution * 65_536).rounded()))
        data.u32(fixed); data.u16(1); data.u16(1)   // pixels per inch, inches
        data.u32(fixed); data.u16(1); data.u16(1)
        section.u32(UInt32(data.count))
        section.append(data.slice)
        section.pad(to: 2)                 // resource data pads to even
        file.u32(UInt32(section.count))
        file.append(section.slice)
    }

    // MARK: Layer & Mask

    private struct Record {
        enum GroupKind { case none, seal, header }
        var rect = PSDRect(top: 0, left: 0, bottom: 0, right: 0)
        /// Encoded channel bodies in emission order; each carries its compression code.
        var channels: [(id: Int16, body: [UInt8])] = []
        var blendKey = "norm"
        var opacity: UInt8 = 255
        var isClipped = false
        var isHidden = false
        var groupKind = GroupKind.none
        var name = ""
        var maskRect: PSDRect?
        var maskDisabled = false
        var isGroup: Bool { groupKind != .none }
    }

    private static func appendLayerAndMask(_ file: inout PSDWriter, snapshot: ProjectSnapshot) throws {
        let layers = snapshot.manifest.layers
        let children = Dictionary(grouping: layers, by: \.parentID)
        var records = [Record]()
        func emit(_ parent: UUID?, depth: Int) throws {
            guard depth <= 64 else { throw ProjectError.invalid }
            for layer in children[parent] ?? [] {
                if layer.isGroup == true {
                    // File order inside a group: bottom seal, children bottom-up, header.
                    records.append(Record(isHidden: !layer.isVisible, groupKind: .seal, name: layer.name))
                    try emit(layer.id, depth: depth + 1)
                    var header = Record(isHidden: !layer.isVisible, groupKind: .header, name: layer.name)
                    try attachMask(layer, snapshot: snapshot, to: &header)
                    records.append(header)
                } else {
                    var record = Record(blendKey: PSDFormat.psdKey(for: layer.blendMode ?? .normal),
                                        opacity: UInt8((max(0, min(1, layer.opacity ?? 1)) * 255).rounded()),
                                        isHidden: !layer.isVisible, name: layer.name)
                    record.isClipped = layer.maskSourceID != nil
                    if let image = snapshot.images[layer.id]?.image {
                        record.rect = try attach(image, transform: layer.transform, name: layer.name, to: &record)
                    }
                    // Adjustment layers and never-painted layers keep their place in the stack
                    // as empty records; only the flattened composite shows their effect.
                    try attachMask(layer, snapshot: snapshot, to: &record)
                    records.append(record)
                }
            }
        }
        try emit(nil, depth: 0)
        for index in records.indices {
            // Every record lists the four structure channels (empty when there are no pixels),
            // so a masked-but-empty record still carries R, G, B and alpha slots.
            let present = Set(records[index].channels.map(\.id))
            for id in [Int16(-1), 0, 1, 2] where !present.contains(id) {
                records[index].channels.append((id, emptyChannel))
            }
        }

        var section = PSDWriter()
        section.i16(Int16(records.count))
        for record in records { writeRecordHeader(&section, record) }
        for record in records { for channel in record.channels { section.append(channel.body) } }
        section.pad(to: 4)
        var outer = PSDWriter()
        let lengthOffset = outer.count
        outer.u32(0)
        outer.append(section.slice)
        outer.patchU32(at: lengthOffset, UInt32(section.count)) // records + channel data + padding
        outer.u32(0) // global layer mask info, empty
        // Global tagged blocks follow directly with no length prefix; none are written, so
        // the Layer & Mask section ends here and the composite begins.
        file.u32(UInt32(outer.count))
        file.append(outer.slice)
    }

    private static let emptyChannel: [UInt8] = [0, 0] // compression 0 (raw), no bytes: a length-2 channel

    /// Extracts a straight-alpha RGBA buffer from a premultiplied image.
    private static func rgbaPixels(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.encode }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.encode }
        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * 4)
        vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        return (Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)),
                width, height)
    }

    /// A grayscale image's bytes in its own grid.
    private static func grayPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.encode }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.encode }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    /// Attaches a layer's RGBA channels, baking rotation, flips and any transform/asset size
    /// difference into the pixels (a PSD rect is axis-aligned and its channels must match its
    /// size), and returns the record rect the raster occupies.
    @discardableResult
    private static func attach(_ image: CGImage, transform: LayerTransform, name: String,
                               to record: inout Record) throws -> PSDRect {
        var rect = PSDRect(top: Int(transform.origin.y.rounded(.down)), left: Int(transform.origin.x.rounded(.down)),
                           bottom: Int((transform.origin.y + transform.size.height).rounded(.up)),
                           right: Int((transform.origin.x + transform.size.width).rounded(.up)))
        if transform.rotation != 0 || transform.flipX || transform.flipY {
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
                .map { transform.point($0) }
            rect = PSDRect(top: Int(corners.map(\.y).min()!.rounded(.down)),
                           left: Int(corners.map(\.x).min()!.rounded(.down)),
                           bottom: Int(corners.map(\.y).max()!.rounded(.up)),
                           right: Int(corners.map(\.x).max()!.rounded(.up)))
        }
        // A PSD scanline table counts row bytes in u16s; a side past 30,000 no longer
        // round-trips, so refuse the layer by name rather than truncate its rows silently —
        // before the bake allocates a rect-sized buffer.
        guard rect.width <= 30_000, rect.height <= 30_000 else { throw ExportError.layerTooLarge(name) }
        var raster = image
        if transform.rotation != 0 || transform.flipX || transform.flipY
            || raster.width != rect.width || raster.height != rect.height {
            let width = rect.width, height = rect.height
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.encode }
            // Flip into the app's top-left document space, then confine it to the bake box.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -CGFloat(rect.left), y: -CGFloat(rect.top))
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
            guard let baked = context.makeImage() else { throw ExportError.encode }
            raster = baked
        }
        let (pixels, width, height) = try rgbaPixels(raster)
        guard width <= 30_000, height <= 30_000 else { throw ExportError.layerTooLarge(name) }
        for (index, channelID) in [Int16(0), 1, 2, -1].enumerated() {
            var plane = [UInt8](repeating: 0, count: width * height)
            for pixel in 0..<(width * height) { plane[pixel] = pixels[pixel * 4 + index] }
            record.channels.append((channelID, PSDFormat.rleChannel(plane[...], width: width, height: height)))
        }
        return rect
    }

    /// Attaches the -2 user mask channel (white reveals, matching the app's grayscale masks)
    /// plus the mask block facts the header records.
    private static func attachMask(_ layer: ProjectLayerRecord, snapshot: ProjectSnapshot, to record: inout Record) throws {
        guard let asset = snapshot.masks[layer.id] else { return }
        var raster = asset.image
        var rect = record.rect
        if let placement = layer.maskPlacement {
            rect = PSDRect(top: Int(placement.origin.y.rounded(.down)), left: Int(placement.origin.x.rounded(.down)),
                           bottom: Int((placement.origin.y + placement.size.height).rounded(.up)),
                           right: Int((placement.origin.x + placement.size.width).rounded(.up)))
            if placement.rotation != 0 || placement.flipX || placement.flipY {
                let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
                    .map { placement.point($0) }
                rect = PSDRect(top: Int(corners.map(\.y).min()!.rounded(.down)),
                               left: Int(corners.map(\.x).min()!.rounded(.down)),
                               bottom: Int(corners.map(\.y).max()!.rounded(.up)),
                               right: Int(corners.map(\.x).max()!.rounded(.up)))
            }
        }
        guard rect.width > 0, rect.height > 0, raster.width > 0, raster.height > 0 else { return }
        // Same 30,000-per-side rule as layers, checked before any bake-sized allocation.
        guard rect.width <= 30_000, rect.height <= 30_000 else { throw ExportError.layerTooLarge(layer.name) }
        if let placement = layer.maskPlacement,
           placement.rotation != 0 || placement.flipX || placement.flipY
            || raster.width != rect.width || raster.height != rect.height {
            let width = rect.width, height = rect.height
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ExportError.encode }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -CGFloat(rect.left), y: -CGFloat(rect.top))
            // Coverage drawing: white inside the mask's ink, black elsewhere.
            context.translateBy(x: placement.center.x, y: placement.center.y)
            context.rotate(by: placement.radians)
            context.scaleBy(x: placement.flipX ? -1 : 1, y: placement.flipY ? 1 : -1)
            let bounds = CGRect(x: -placement.size.width / 2, y: -placement.size.height / 2,
                                width: placement.size.width, height: placement.size.height)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(bounds)
            context.clip(to: bounds, mask: raster)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            guard let baked = context.makeImage() else { throw ExportError.encode }
            raster = baked
        }
        guard raster.width <= 30_000, raster.height <= 30_000 else { throw ExportError.layerTooLarge(layer.name) }
        record.maskRect = rect
        record.maskDisabled = layer.maskEnabled == false
        record.channels.append((-2, PSDFormat.rleChannel(try grayPixels(raster)[...],
                                                         width: raster.width, height: raster.height)))
    }

    private static func writeRecordHeader(_ section: inout PSDWriter, _ record: Record) {
        section.i32(Int32(record.rect.top)); section.i32(Int32(record.rect.left))
        section.i32(Int32(record.rect.bottom)); section.i32(Int32(record.rect.right))
        section.u16(UInt16(record.channels.count))
        for channel in record.channels { section.i16(channel.id); section.u32(UInt32(channel.body.count)) }
        section.append(PSDFormat.blockSignature)
        section.ascii(record.blendKey.count == 4 ? record.blendKey : "norm")
        section.append(record.opacity)
        section.append(record.isClipped ? 1 : 0)
        var flags: UInt8 = 8 // "Photoshop 5.0 and later" bit, always set
        if record.isHidden { flags |= 2 }
        if record.isGroup { flags |= 16 } // pixel data irrelevant
        section.append(flags)
        section.append(0) // filler

        var extra = PSDWriter()
        if let maskRect = record.maskRect {
            var block = PSDWriter()
            block.i32(Int32(maskRect.top)); block.i32(Int32(maskRect.left))
            block.i32(Int32(maskRect.bottom)); block.i32(Int32(maskRect.right))
            block.append(255) // background: white (reveal) outside the mask rect
            block.append(record.maskDisabled ? 2 : 0)
            block.pad(to: 4)
            extra.u32(UInt32(block.count))
            extra.append(block.slice)
        } else {
            extra.u32(0)
        }
        extra.u32(0) // blending ranges
        let asciiName = String(record.name.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        let bytes = Array(String(asciiName.prefix(255)).utf8)
        extra.append(UInt8(bytes.count))
        extra.append(bytes)
        extra.append([UInt8](repeating: 0, count: (4 - (1 + bytes.count) % 4) % 4)) // (1+n) pads to a multiple of 4
        switch record.groupKind {
        case .seal:
            var block = PSDWriter()
            block.u32(3) // bounding-section divider: the group's bottom marker
            appendTaggedBlock(&extra, key: "lsct", data: block)
        case .header:
            var block = PSDWriter()
            block.u32(1) // open folder
            block.ascii("8BIM")
            block.ascii("pass") // folders here blend pass-through, which is what this key means
            block.u32(0)
            appendTaggedBlock(&extra, key: "lsct", data: block)
        case .none:
            break
        }
        var luni = PSDWriter()
        let units = Array(record.name.utf16)
        luni.u32(UInt32(units.count))
        for unit in units { luni.u16(unit) }
        appendTaggedBlock(&extra, key: "luni", data: luni)
        extra.pad(to: 2)
        section.u32(UInt32(extra.count))
        section.append(extra.slice)
    }

    private static func appendTaggedBlock(_ extra: inout PSDWriter, key: String, data: PSDWriter) {
        var block = data
        block.pad(to: 2)
        extra.append(PSDFormat.blockSignature)
        extra.ascii(key)
        extra.u32(UInt32(block.count))
        extra.append(block.slice)
    }

    // MARK: composite

    /// The composite section: RLE over every scanline of every channel, in R,G,B,A order.
    private static func appendComposite(_ file: inout PSDWriter, image: CGImage) throws {
        let (pixels, width, height) = try rgbaPixels(image)
        var section = PSDWriter()
        section.u16(1)
        var rows = [[UInt8]]()
        rows.reserveCapacity(4 * height)
        for channel in 0..<4 {
            for y in 0..<height {
                var plane = [UInt8](repeating: 0, count: width)
                for x in 0..<width { plane[x] = pixels[(y * width + x) * 4 + channel] }
                rows.append(PSDFormat.packBits(plane[...]))
            }
        }
        for row in rows { section.u16(UInt16(clamping: row.count)) }
        for row in rows { section.append(row) }
        file.append(section.slice)
    }
}
