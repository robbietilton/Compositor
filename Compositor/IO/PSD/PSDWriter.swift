import CoreGraphics
import Foundation

/// Writes a document as a layered Photoshop `.psd`, from Adobe's *Photoshop File Formats Specification*, for handing
/// work to people on Photoshop or After Effects. Pixel layers keep their names, places, opacity, visibility, blend
/// modes and masks; folders become groups and clipping stacks stay clipped. Text, shapes and layer effects go out as
/// the pixels they draw; adjustment layers are left out. A flattened copy is written too, for apps that don't read
/// layers. With a 16-bit layer in the document, the whole file is 16 bits a channel.
nonisolated enum PSDWriter {
    /// Something that doesn't go into the file as it is in Compositor, said in the Export As sheet.
    struct Note: Equatable {
        let layerName: String
        let change: Change
        enum Change: Equatable { case textAsPixels, effectsAsPixels, adjustmentLeftOut }
    }

    /// What `write` will change, in layer order, top first.
    static func notes(for snapshot: ProjectSnapshot) -> [Note] {
        snapshot.manifest.layers.reversed().compactMap { layer -> Note? in
            if layer.adjustment != nil { return Note(layerName: layer.name, change: .adjustmentLeftOut) }
            guard layer.isGroup != true else { return nil }
            if let effects = layer.effects?.visible, !effects.isEmpty, effects.isValid {
                return Note(layerName: layer.name, change: .effectsAsPixels)
            }
            if layer.text != nil { return Note(layerName: layer.name, change: .textAsPixels) }
            return nil
        }
    }

    /// The notes as a line or two for the sheet, nil when nothing changes.
    static func summary(_ notes: [Note]) -> String? {
        func names(_ change: Note.Change) -> String? {
            let matching = notes.filter { $0.change == change }.map(\.layerName)
            guard !matching.isEmpty else { return nil }
            let shown = matching.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            return matching.count > 3 ? "\(shown) and \(matching.count - 3) more" : shown
        }
        let lines = [
            names(.textAsPixels).map { "Text drawn as pixels: \($0)" },
            names(.effectsAsPixels).map { "Effects drawn into the pixels: \($0)" },
            names(.adjustmentLeftOut).map { "Adjustment layers left out: \($0)" },
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The file: `composite` is the document flattened (as `ImageExporter.render` draws it), at 16 bits a channel when
    /// `sixteenBit`.
    static func write(_ snapshot: ProjectSnapshot, composite: CGImage, sixteenBit: Bool) throws -> Data {
        let width = snapshot.manifest.width, height = snapshot.manifest.height
        guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else {
            throw ExportError.tooLarge
        }
        let depth = sixteenBit ? 2 : 1
        var file = PSDBytes()
        // Header: RGB with an alpha channel, which a negative layer count below makes the composite's transparency.
        file.ascii("8BPS"); file.u16(1); file.zeros(6)
        file.u16(4); file.u32(height); file.u32(width); file.u16(depth * 8); file.u16(3)
        file.u32(0) // no color mode data
        file.data(resources(resolution: snapshot.manifest.resolution ?? 72), lengthPrefixed: true)
        file.data(try layerSection(snapshot, sixteenBit: sixteenBit), lengthPrefixed: true)
        // The flattened image: every plane's rows counted first, then the planes, R, G, B and A.
        guard composite.width == width, composite.height == height else { throw ExportError.render }
        let planes = try Self.planes(of: composite, sixteenBit: sixteenBit)
        if sixteenBit {
            file.u16(0)
            for plane in planes { file.data(plane) }
        } else {
            file.u16(1)
            let packed = planes.map { PackBits.rows($0, width: width, height: height) }
            for plane in packed { for row in plane { file.u16(row.count) } }
            for plane in packed { for row in plane { file.data(row) } }
        }
        return file.bytes
    }

    // MARK: Sections

    /// Resolution, and the sRGB profile the pixels are in.
    private static func resources(resolution: Double) -> Data {
        var out = PSDBytes()
        func resource(_ id: Int, _ body: Data) {
            out.ascii("8BIM"); out.u16(id); out.u16(0) // empty, padded name
            out.u32(body.count); out.data(body)
            if body.count % 2 == 1 { out.zeros(1) }
        }
        var info = PSDBytes()
        let fixed = UInt32(max(1, min(9600, resolution)) * 65536)
        info.u32(Int(fixed)); info.u16(1); info.u16(1) // pixels per inch, shown in inches
        info.u32(Int(fixed)); info.u16(1); info.u16(1)
        resource(1005, info.bytes)
        if let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? { resource(1039, profile) }
        return out.bytes
    }

    private struct Record {
        var name: String
        var rect = PSDRect.empty
        var channels: [(id: Int, data: Data)] = []
        var blendKey = "norm"
        var opacity: Double = 1
        var clipping = false
        var hidden = false
        var mask: (rect: PSDRect, defaultValue: UInt8, disabled: Bool, unlinked: Bool)?
        /// 1 an open group, 3 the divider closing it; nil a layer.
        var section: Int?
    }

    private static func layerSection(_ snapshot: ProjectSnapshot, sixteenBit: Bool) throws -> Data {
        let layers = snapshot.manifest.layers
        let children = Dictionary(grouping: layers, by: \.parentID)
        var records: [Record] = []
        // Photoshop's order is bottom to top; a group is its divider, its contents, then the group itself.
        func visit(_ parent: UUID?, depth: Int) throws {
            guard depth <= 64 else { return }
            for layer in children[parent] ?? [] {
                try Task.checkCancellation()
                if layer.isGroup == true {
                    var divider = Record(name: "</Layer group>")
                    divider.section = 3
                    divider.channels = emptyChannels(sixteenBit: sixteenBit)
                    records.append(divider)
                    try visit(layer.id, depth: depth + 1)
                    var group = Record(name: layer.name)
                    group.section = 1
                    group.blendKey = "pass"
                    group.opacity = layer.opacity ?? 1
                    group.hidden = !layer.isVisible
                    group.channels = emptyChannels(sixteenBit: sixteenBit)
                    try addFolderMask(layer, snapshot: snapshot, to: &group, sixteenBit: sixteenBit)
                    records.append(group)
                } else if layer.adjustment == nil {
                    records.append(try record(for: layer, snapshot: snapshot, sixteenBit: sixteenBit))
                }
            }
        }
        try visit(nil, depth: 0)

        var info = PSDBytes()
        info.i16(-records.count)
        for record in records {
            info.i32(record.rect.top); info.i32(record.rect.left); info.i32(record.rect.bottom); info.i32(record.rect.right)
            info.u16(record.channels.count)
            for channel in record.channels { info.i16(channel.id); info.u32(channel.data.count) }
            info.ascii("8BIM"); info.ascii(record.blendKey)
            info.u8(Int((min(1, max(0, record.opacity)) * 255).rounded()))
            info.u8(record.clipping ? 1 : 0)
            // Bit 1 hides the layer; bit 3 says bit 4 means something, and bit 4 that a group's pixels don't.
            info.u8((record.hidden ? 2 : 0) | (record.section == nil ? 0 : 8 | 16))
            info.u8(0)
            var extra = PSDBytes()
            if let mask = record.mask {
                extra.u32(20)
                extra.i32(mask.rect.top); extra.i32(mask.rect.left); extra.i32(mask.rect.bottom); extra.i32(mask.rect.right)
                extra.u8(Int(mask.defaultValue))
                extra.u8((mask.unlinked ? 1 : 0) | (mask.disabled ? 2 : 0))
                extra.zeros(2)
            } else {
                extra.u32(0)
            }
            extra.u32(0) // no blending ranges
            let name = Array(record.name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(255)
            extra.u8(name.count); extra.data(Data(name))
            extra.zeros((4 - (name.count + 1) % 4) % 4)
            var unicode = PSDBytes()
            let utf16 = Array(record.name.utf16)
            unicode.u32(utf16.count)
            for unit in utf16 { unicode.u16(Int(unit)) }
            extra.block("luni", unicode.bytes)
            if let section = record.section {
                var divider = PSDBytes()
                divider.u32(section)
                if section != 3 { divider.ascii("8BIM"); divider.ascii(record.blendKey) }
                extra.block("lsct", divider.bytes)
            }
            info.data(extra.bytes, lengthPrefixed: true)
        }
        for record in records { for channel in record.channels { info.data(channel.data) } }
        if info.bytes.count % 2 == 1 { info.zeros(1) }

        var section = PSDBytes()
        section.data(info.bytes, lengthPrefixed: true)
        section.u32(0) // no global layer mask
        return section.bytes
    }

    // MARK: Layers

    /// A layer as it draws on its own, on the document: placed, rotated, flipped and scaled, with its effects, at full
    /// opacity and in Normal, trimmed to its pixels. Its mask goes alongside, unless effects drew it into the pixels.
    private static func record(for layer: ProjectLayerRecord, snapshot: ProjectSnapshot, sixteenBit: Bool) throws -> Record {
        var record = Record(name: layer.name)
        record.blendKey = (layer.blendMode ?? .normal).psdKey
        record.opacity = layer.opacity ?? 1
        record.hidden = !layer.isVisible
        record.clipping = layer.maskSourceID != nil
        let canvas = CGRect(x: 0, y: 0, width: snapshot.manifest.width, height: snapshot.manifest.height)
        guard let asset = snapshot.images[layer.id] else {
            record.channels = emptyChannels(sixteenBit: sixteenBit)
            return record
        }
        let image = sixteenBit ? (try? DeepLayer.flattened(asset)) ?? asset.image : asset.image
        let fullMask = snapshot.mask(for: layer).map { LayerMask(asset: $0.asset, isEnabled: true, placement: $0.placement, isLinked: $0.isLinked) }
        let maskGrid = fullMask?.clipImage(placement: fullMask?.placement, over: layer.transform, width: image.width, height: image.height)
        let effects = LayerEffectsRenderer.cached(image, mask: snapshot.mask(for: layer)?.enabledImage == nil ? nil : maskGrid,
                                                  effects: layer.effects)
        let placement = effects.map { LayerEffectsRenderer.placed(layer.transform, image: $0.image, inset: $0.inset) } ?? layer.transform
        let area = bounds(of: placement).intersection(canvas).integral
        guard !area.isEmpty else {
            record.channels = emptyChannels(sixteenBit: sixteenBit)
            return record
        }
        let context = try surface(area, sixteenBit: sixteenBit, gray: false)
        LayerRenderer.draw(effects?.image ?? image, transform: placement, center: placement.center, in: context)
        var planes = try straightPlanes(context, sixteenBit: sixteenBit)
        guard let trimmed = trim(alpha: planes[3], width: Int(area.width), height: Int(area.height), sixteenBit: sixteenBit) else {
            record.channels = emptyChannels(sixteenBit: sixteenBit)
            return record
        }
        planes = planes.map { crop($0, width: Int(area.width), to: trimmed, sixteenBit: sixteenBit) }
        let rect = PSDRect(trimmed.offsetBy(dx: area.minX, dy: area.minY))
        record.rect = rect
        record.channels = zip([0, 1, 2, -1], planes).map { ($0, channel($1, width: rect.width, height: rect.height, sixteenBit: sixteenBit)) }
        if effects == nil, let maskGrid, let mask = fullMask {
            // On the layer's pixels, as the layer draws; everywhere else Photoshop's default, showing.
            let context = try surface(area, sixteenBit: sixteenBit, gray: true)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(area)
            LayerRenderer.draw(maskGrid, transform: layer.transform, center: layer.transform.center, in: context)
            let gray = crop(try grayPlane(context, sixteenBit: sixteenBit), width: Int(area.width), to: trimmed, sixteenBit: sixteenBit)
            record.mask = (rect, 255, !mask.isEnabled, !mask.isLinked)
            record.channels.append((-2, channel(gray, width: rect.width, height: rect.height, sixteenBit: sixteenBit)))
        }
        return record
    }

    /// A folder's mask, over the whole canvas.
    private static func addFolderMask(_ folder: ProjectLayerRecord, snapshot: ProjectSnapshot, to record: inout Record,
                                      sixteenBit: Bool) throws {
        guard let mask = snapshot.mask(for: folder) else { return }
        let canvas = CGRect(x: 0, y: 0, width: snapshot.manifest.width, height: snapshot.manifest.height)
        let context = try surface(canvas, sixteenBit: sixteenBit, gray: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(canvas)
        LayerRenderer.draw(mask.asset.image, transform: folder.transform, center: folder.transform.center, in: context)
        let rect = PSDRect(canvas)
        record.mask = (rect, 0, !mask.isEnabled, false)
        record.channels.append((-2, channel(try grayPlane(context, sixteenBit: sixteenBit), width: rect.width, height: rect.height,
                                            sixteenBit: sixteenBit)))
    }

    /// The four channels of a layer with no pixels: nothing but each one's compression.
    private static func emptyChannels(sixteenBit: Bool) -> [(id: Int, data: Data)] {
        [0, 1, 2, -1].map { ($0, Data([0, 0])) }
    }

    /// A channel's data: PackBits for 8 bits, raw for 16 (Photoshop's own 16-bit choice is zip).
    private static func channel(_ plane: Data, width: Int, height: Int, sixteenBit: Bool) -> Data {
        var out = PSDBytes()
        if sixteenBit || width == 0 || height == 0 {
            out.u16(0); out.data(plane)
            return out.bytes
        }
        let rows = PackBits.rows(plane, width: width, height: height)
        out.u16(1)
        for row in rows { out.u16(row.count) }
        for row in rows { out.data(row) }
        return out.bytes
    }

    // MARK: Pixels

    /// The area of the document a placed layer covers.
    static func bounds(of transform: LayerTransform) -> CGRect {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(transform.point)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A surface for `area` of the document, its top row first in memory, drawn on in document coordinates. Gray is
    /// device gray, as masks are, so their values go through unchanged.
    private static func surface(_ area: CGRect, sixteenBit: Bool, gray: Bool) throws -> CGContext {
        let width = Int(area.width), height = Int(area.height)
        let bytes = sixteenBit ? 2 : 1
        guard let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bytes * 8,
                                      bytesPerRow: width * bytes * (gray ? 1 : 4), space: space,
                                      bitmapInfo: (gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
                                          | (sixteenBit ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) else {
            throw ExportError.render
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        return context
    }

    /// An image's red, green, blue and alpha planes, straight (not premultiplied), big-endian at 16 bits.
    static func planes(of image: CGImage, sixteenBit: Bool) throws -> [Data] {
        let width = image.width, height = image.height
        let context = try surface(CGRect(x: 0, y: 0, width: width, height: height), sixteenBit: sixteenBit, gray: false)
        context.setBlendMode(.copy)
        // Undo the surface's flip: an image already draws top row up.
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try straightPlanes(context, sixteenBit: sixteenBit)
    }

    /// A `surface`'s red, green, blue and alpha planes, straight, big-endian at 16 bits.
    private static func straightPlanes(_ context: CGContext, sixteenBit: Bool) throws -> [Data] {
        let width = context.width, height = context.height
        guard let base = context.data else { throw ExportError.render }
        let count = width * height
        var planes = (0..<4).map { _ in Data(count: count * (sixteenBit ? 2 : 1)) }
        if sixteenBit {
            let pixels = base.assumingMemoryBound(to: UInt16.self)
            let stride = context.bytesPerRow / 2
            for c in 0..<4 {
                planes[c].withUnsafeMutableBytes { raw in
                    let out = raw.bindMemory(to: UInt16.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let p = y * stride + x * 4
                            let alpha = UInt32(UInt16(littleEndian: pixels[p + 3]))
                            var value = UInt32(UInt16(littleEndian: pixels[p + c]))
                            if c < 3 { value = alpha == 0 ? 0 : min(65535, (value * 65535 + alpha / 2) / alpha) }
                            out[y * width + x] = UInt16(value).bigEndian
                        }
                    }
                }
            }
        } else {
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let stride = context.bytesPerRow
            for c in 0..<4 {
                planes[c].withUnsafeMutableBytes { raw in
                    let out = raw.bindMemory(to: UInt8.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let p = y * stride + x * 4
                            let alpha = UInt32(pixels[p + 3])
                            var value = UInt32(pixels[p + c])
                            if c < 3 { value = alpha == 0 ? 0 : min(255, (value * 255 + alpha / 2) / alpha) }
                            out[y * width + x] = UInt8(value)
                        }
                    }
                }
            }
        }
        return planes
    }

    /// A gray `surface`'s one plane, big-endian at 16 bits.
    private static func grayPlane(_ context: CGContext, sixteenBit: Bool) throws -> Data {
        let width = context.width, height = context.height, bytes = sixteenBit ? 2 : 1
        guard let base = context.data else { throw ExportError.render }
        var plane = Data(count: width * height * bytes)
        plane.withUnsafeMutableBytes { out in
            for y in 0..<height {
                memcpy(out.baseAddress! + y * width * bytes, base + y * context.bytesPerRow, width * bytes)
            }
            if sixteenBit {
                let values = out.bindMemory(to: UInt16.self)
                for index in values.indices { values[index] = UInt16(littleEndian: values[index]).bigEndian }
            }
        }
        return plane
    }

    /// The smallest rectangle holding every pixel with any alpha, nil when there's none.
    private static func trim(alpha: Data, width: Int, height: Int, sixteenBit: Bool) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        let bytes = sixteenBit ? 2 : 1
        alpha.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * bytes
                    if values[p] != 0 || (sixteenBit && values[p + 1] != 0) {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func crop(_ plane: Data, width: Int, to rect: CGRect, sixteenBit: Bool) -> Data {
        let bytes = sixteenBit ? 2 : 1
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        if x == 0, y == 0, w == width { return plane.prefix(w * h * bytes) }
        var out = Data(capacity: w * h * bytes)
        for row in y..<(y + h) {
            let start = (row * width + x) * bytes
            out.append(plane[(plane.startIndex + start)..<(plane.startIndex + start + w * bytes)])
        }
        return out
    }
}

/// A rectangle as Photoshop stores it: top, left, bottom, right.
nonisolated struct PSDRect: Equatable {
    var top = 0, left = 0, bottom = 0, right = 0
    static let empty = PSDRect()
    var width: Int { right - left }
    var height: Int { bottom - top }
    init() {}
    init(_ rect: CGRect) {
        top = Int(rect.minY); left = Int(rect.minX); bottom = Int(rect.maxY); right = Int(rect.maxX)
    }
}

/// Photoshop's run-length compression, a row at a time.
nonisolated enum PackBits {
    static func rows(_ plane: Data, width: Int, height: Int) -> [Data] {
        plane.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0..<height).map { row in pack(UnsafeBufferPointer(rebasing: bytes[(row * width)..<((row + 1) * width)])) }
        }
    }

    static func pack(_ row: UnsafeBufferPointer<UInt8>) -> Data {
        var out = Data(capacity: row.count + row.count / 128 + 1)
        var index = 0
        while index < row.count {
            // A run of three or more of the same byte packs; anything shorter goes out as it is.
            var run = 1
            while index + run < row.count, run < 128, row[index + run] == row[index] { run += 1 }
            if run >= 3 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(row[index])
                index += run
                continue
            }
            var end = index
            while end < row.count, end - index < 128 {
                if end + 2 < row.count, row[end] == row[end + 1], row[end] == row[end + 2] { break }
                end += 1
            }
            out.append(UInt8(end - index - 1))
            out.append(contentsOf: row[index..<end])
            index = end
        }
        return out
    }
}

/// Big-endian bytes, as every number in a Photoshop file is.
nonisolated struct PSDBytes {
    var bytes = Data()
    mutating func u8(_ value: Int) { bytes.append(UInt8(truncatingIfNeeded: value)) }
    mutating func u16(_ value: Int) { u8(value >> 8); u8(value) }
    mutating func i16(_ value: Int) { u16(Int(UInt16(bitPattern: Int16(value)))) }
    mutating func u32(_ value: Int) { u16(value >> 16); u16(value) }
    mutating func i32(_ value: Int) { u32(Int(UInt32(bitPattern: Int32(value)))) }
    mutating func zeros(_ count: Int) { bytes.append(Data(count: count)) }
    mutating func ascii(_ text: String) { bytes.append(Data(text.utf8)) }
    mutating func data(_ data: Data, lengthPrefixed: Bool = false) {
        if lengthPrefixed { u32(data.count) }
        bytes.append(data)
    }
    /// An additional layer information block, padded to an even length.
    mutating func block(_ key: String, _ body: Data) {
        ascii("8BIM"); ascii(key)
        let padded = body.count + body.count % 2
        u32(padded); bytes.append(body); zeros(padded - body.count)
    }
}

extension LayerBlendMode {
    /// The key Photoshop stores for the mode (the reverse of `fromPSD`).
    nonisolated var psdKey: String {
        switch self {
        case .normal: "norm"
        case .multiply: "mul "
        case .screen: "scrn"
        case .overlay: "over"
        case .softLight: "sLit"
        case .darken: "dark"
        case .lighten: "lite"
        case .difference: "diff"
        case .colorDodge: "div "
        case .colorBurn: "idiv"
        case .hue: "hue "
        case .saturation: "sat "
        case .color: "colr"
        case .luminosity: "lum "
        case .linearBurn: "lbrn"
        case .linearDodge: "lddg"
        case .hardLight: "hLit"
        case .vividLight: "vLit"
        case .linearLight: "lLit"
        case .pinLight: "pLit"
        case .hardMix: "hMix"
        case .exclusion: "smud"
        case .subtract: "fsub"
        case .divide: "fdiv"
        }
    }
}
