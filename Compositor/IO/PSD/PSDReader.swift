import CoreGraphics
import Foundation

nonisolated enum PSDReader {
    private struct ChannelInfo {
        var id: Int16
        var dataLength: Int
    }
    private struct MaskInfo {
        var top, left, bottom, right: Int
        var defaultColor: UInt8
        var disabled: Bool
        var invert: Bool
        var relative: Bool
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
    }
    private enum Section {
        case none, divider, folder
    }
    private struct RawLayer {
        var top, left, bottom, right: Int
        var channels: [ChannelInfo]
        var blend: LayerBlendMode
        var opacity: Double
        var clipped: Bool
        var hidden: Bool
        var name: String
        var mask: MaskInfo?
        var section = Section.none
        var adjustment: LayerAdjustment?
        var pixels: PSDPixels.RGBA?
        var maskPlane: [UInt8]?
        var width: Int { max(0, right - left) }
        var height: Int { max(0, bottom - top) }
    }

    static func parse(_ data: Data) throws -> ProjectSnapshot {
        guard data.count <= 512 * 1024 * 1024 else { throw PSDError.tooLarge }
        let cursor = PSDCursor(data)
        guard try cursor.fourCC() == PSDFourCC.file else { throw PSDError.invalid }
        let version = try cursor.u16()
        guard version != 2 else { throw PSDError.unsupportedVersion }
        guard version == 1 else { throw PSDError.invalid }
        try cursor.skip(6)
        let channelCount = Int(try cursor.u16())
        let height = Int(try cursor.u32())
        let width = Int(try cursor.u32())
        let depth = try cursor.u16()
        let colorMode = try cursor.u16()
        guard (1...56).contains(channelCount) else { throw PSDError.invalid }
        guard (1...30_000).contains(width), (1...30_000).contains(height), width * height <= 100_000_000 else {
            throw PSDError.tooLarge
        }
        guard depth == 8 else { throw PSDError.unsupportedDepth }
        guard colorMode == 1 || colorMode == 3 else { throw PSDError.unsupportedColorMode }
        try cursor.skip(Int(try cursor.u32())) // Color mode data.
        let (resolution, activeIndex) = try readResources(cursor)
        let layers = try readLayerSection(cursor, documentWidth: width, documentHeight: height, grayscale: colorMode == 1)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var records: [ProjectLayerRecord] = []
        var pixelsUsed = 0
        if layers.isEmpty {
            let composite = try readComposite(cursor, width: width, height: height, channels: channelCount, grayscale: colorMode == 1)
            let id = UUID()
            images[id] = try PSDPixels.imported(composite, name: "Background")
            records.append(ProjectLayerRecord(id: id, name: "Background", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)),
                imageFile: "\(id.uuidString).png"))
            pixelsUsed = width * height
        } else {
            try assemble(layers, into: &records, images: &images, masks: &masks, pixelsUsed: &pixelsUsed,
                         canvas: CGSize(width: width, height: height))
        }
        guard records.count <= 10_000 else { throw PSDError.tooLarge }
        try LayerHierarchy.validate(records)
        try LiveMaskGraph.validate(records)
        let active: UUID?
        if let activeIndex, records.indices.contains(activeIndex) { active = records[activeIndex].id }
        else { active = records.last?.id }
        let manifest = ProjectManifest(resolution: resolution, documentID: UUID(), width: width, height: height,
            activeLayerID: active, layers: records)
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks)
    }

    private static func readResources(_ cursor: PSDCursor) throws -> (Double, Int?) {
        let length = Int(try cursor.u32())
        let end = cursor.offset + length
        guard end <= cursor.data.count else { throw PSDError.invalid }
        var resolution = 72.0
        var activeIndex: Int?
        while cursor.offset + 12 <= end {
            let signature = try cursor.fourCC()
            guard signature == PSDFourCC.resource else { throw PSDError.invalid }
            let id = try cursor.u16()
            _ = try cursor.pascal(paddedTo: 2)
            let length = Int(try cursor.u32())
            let payload = try cursor.bytes(length)
            if length % 2 == 1 { try cursor.skip(1) }
            switch id {
            case 1005:
                if payload.count >= 4 {
                    let hRes = Double(Int32(bitPattern: readU32(payload))) / 65536
                    if hRes.isFinite, (1...9600).contains(hRes) { resolution = hRes }
                }
            case 1024:
                if payload.count >= 2 {
                    activeIndex = Int(readU16(payload))
                }
            default: break
            }
        }
        cursor.offset = end
        return (resolution, activeIndex)
    }

    private static func readLayerSection(_ cursor: PSDCursor, documentWidth: Int, documentHeight: Int, grayscale: Bool) throws -> [RawLayer] {
        let sectionLength = Int(try cursor.u32())
        let sectionEnd = cursor.offset + sectionLength
        guard sectionEnd <= cursor.data.count else { throw PSDError.invalid }
        if sectionLength == 0 { return [] }
        let infoLength = Int(try cursor.u32())
        let infoEnd = cursor.offset + infoLength
        guard infoEnd <= sectionEnd else { throw PSDError.invalid }
        var layers: [RawLayer] = []
        if infoLength >= 2 {
            let count = abs(Int(try cursor.i16()))
            guard count <= 10_000 else { throw PSDError.tooLarge }
            var records: [RawLayer] = []
            records.reserveCapacity(count)
            for _ in 0..<count { records.append(try readLayerRecord(cursor)) }
            for i in records.indices { try readChannelData(&records[i], cursor: cursor, grayscale: grayscale) }
            layers = records
        }
        cursor.offset = sectionEnd
        _ = documentWidth; _ = documentHeight
        return layers
    }

    private static func readLayerRecord(_ cursor: PSDCursor) throws -> RawLayer {
        let top = Int(try cursor.i32()), left = Int(try cursor.i32())
        let bottom = Int(try cursor.i32()), right = Int(try cursor.i32())
        guard abs(top) <= 1_000_000, abs(left) <= 1_000_000, abs(bottom) <= 1_000_000, abs(right) <= 1_000_000,
              bottom >= top, right >= left else { throw PSDError.invalid }
        let channelCount = Int(try cursor.u16())
        guard (1...56).contains(channelCount) else { throw PSDError.invalid }
        var channels: [ChannelInfo] = []
        channels.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            channels.append(ChannelInfo(id: try cursor.i16(), dataLength: Int(try cursor.u32())))
        }
        guard try cursor.fourCC() == PSDFourCC.resource else { throw PSDError.invalid }
        let blend = PSDBlend.mode(for: try cursor.fourCC())
        let opacity = Double(try cursor.u8()) / 255
        let clipped = try cursor.u8() == 1
        let flags = try cursor.u8()
        try cursor.skip(1)
        let extra = Int(try cursor.u32())
        let extraEnd = cursor.offset + extra
        guard extraEnd <= cursor.data.count else { throw PSDError.invalid }
        let mask = try readMask(cursor)
        let blendRangeLength = Int(try cursor.u32())
        try cursor.skip(blendRangeLength)
        var name = try cursor.pascal(paddedTo: 4)
        var section = Section.none
        var adjustment: LayerAdjustment?
        while cursor.offset + 12 <= extraEnd {
            let signature = try cursor.fourCC()
            guard signature == PSDFourCC.resource || signature == PSDFourCC.resource64 else { break }
            let key = try cursor.fourCC()
            let length = Int(try cursor.u32())
            let padded = length + length % 2
            let payload = try cursor.bytes(min(length, padded))
            if padded > length { try cursor.skip(padded - length) }
            switch key {
            case PSDFourCC.code("luni"):
                let unicode = (try? PSDCursor(payload).unicode())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !unicode.isEmpty { name = unicode }
            case PSDFourCC.code("lsct"):
                if payload.count >= 4 {
                    let type = readU32(payload)
                    if type == 3 { section = .divider }
                    else if type == 1 || type == 2 { section = .folder }
                }
            case PSDFourCC.code("levl"):
                if let parsed = parseLevels(payload) { adjustment = parsed }
            case PSDFourCC.code("curv"):
                if let parsed = parseCurves(payload) { adjustment = parsed }
            case PSDFourCC.code("hue2"), PSDFourCC.code("hue "):
                if let parsed = parseHue(payload) { adjustment = parsed }
            default: break
            }
        }
        cursor.offset = extraEnd
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = section == .folder ? "Folder" : "Layer" }
        if name.utf8.count > 16_384 { name = String(name.prefix(200)) }
        return RawLayer(top: top, left: left, bottom: bottom, right: right, channels: channels, blend: blend,
                        opacity: opacity, clipped: clipped, hidden: (flags & 0x02) != 0, name: name, mask: mask,
                        section: section, adjustment: adjustment)
    }

    private static func readMask(_ cursor: PSDCursor) throws -> MaskInfo? {
        let size = Int(try cursor.u32())
        if size == 0 { return nil }
        let end = cursor.offset + size
        guard end <= cursor.data.count, size >= 18 else {
            try cursor.skip(size)
            return nil
        }
        let top = Int(try cursor.i32()), left = Int(try cursor.i32())
        let bottom = Int(try cursor.i32()), right = Int(try cursor.i32())
        let defaultColor = try cursor.u8()
        let flags = try cursor.u8()
        cursor.offset = end
        guard bottom >= top, right >= left else { return nil }
        return MaskInfo(top: top, left: left, bottom: bottom, right: right, defaultColor: defaultColor,
                        disabled: (flags & 0x02) != 0, invert: (flags & 0x04) != 0, relative: (flags & 0x01) != 0)
    }

    private static func readChannelData(_ layer: inout RawLayer, cursor: PSDCursor, grayscale: Bool) throws {
        var planes: [Int16: [UInt8]] = [:]
        let width = layer.width, height = layer.height
        for channel in layer.channels {
            let start = cursor.offset
            let expected = channel.dataLength
            if expected < 0 { throw PSDError.invalid }
            if expected == 0 { continue }
            let compression = Int(try cursor.u16())
            let isMask = channel.id == -2 || channel.id == -3
            let w = isMask ? (layer.mask?.width ?? 0) : width
            let h = isMask ? (layer.mask?.height ?? 0) : height
            if w == 0 || h == 0 {
                cursor.offset = start + expected
                continue
            }
            var used = 0
            try checkSize(width: w, height: h, used: &used)
            let plane = try PSDPackBits.unpackPlane(cursor, width: w, height: h, compression: compression, expected: expected)
            planes[channel.id] = plane
            cursor.offset = start + expected
        }
        if layer.section == .divider { return }
        if let mask = layer.mask, let plane = planes[-2] ?? planes[-3], mask.width > 0, mask.height > 0 {
            var pixels = plane
            if mask.invert { for i in pixels.indices { pixels[i] = 255 - pixels[i] } }
            layer.maskPlane = pixels
        }
        if layer.adjustment != nil { return }
        let count = width * height
        if count == 0 { return }
        let alpha = planes[-1] ?? [UInt8](repeating: 255, count: count)
        if grayscale {
            let gray = planes[0] ?? [UInt8](repeating: 0, count: count)
            layer.pixels = PSDPixels.RGBA(r: gray, g: gray, b: gray, a: alpha, width: width, height: height)
        } else {
            layer.pixels = PSDPixels.RGBA(r: planes[0] ?? [UInt8](repeating: 0, count: count),
                                          g: planes[1] ?? [UInt8](repeating: 0, count: count),
                                          b: planes[2] ?? [UInt8](repeating: 0, count: count),
                                          a: alpha, width: width, height: height)
        }
    }

    private static func readComposite(_ cursor: PSDCursor, width: Int, height: Int, channels: Int, grayscale: Bool) throws -> PSDPixels.RGBA {
        let compression = Int(try cursor.u16())
        let planeCount = min(channels, grayscale ? 2 : 4)
        var planes: [[UInt8]] = []
        switch compression {
        case 0:
            for _ in 0..<planeCount {
                planes.append([UInt8](try cursor.bytes(width * height)))
            }
        case 1:
            var counts: [[Int]] = Array(repeating: [], count: planeCount)
            for c in 0..<planeCount {
                for _ in 0..<height { counts[c].append(Int(try cursor.u16())) }
            }
            for c in 0..<planeCount {
                var packed = Data()
                for row in counts[c] { packed.append(try cursor.bytes(row)) }
                planes.append(try PSDPackBits.unpack(packed, count: width * height))
            }
        default:
            throw PSDError.unsupportedCompression
        }
        let count = width * height
        if grayscale {
            let gray = planes[0]
            let alpha = planes.count > 1 ? planes[1] : [UInt8](repeating: 255, count: count)
            return PSDPixels.RGBA(r: gray, g: gray, b: gray, a: alpha, width: width, height: height)
        }
        let r = planes[0], g = planes.count > 1 ? planes[1] : r, b = planes.count > 2 ? planes[2] : r
        let alpha = planes.count > 3 ? planes[3] : [UInt8](repeating: 255, count: count)
        return PSDPixels.RGBA(r: r, g: g, b: b, a: alpha, width: width, height: height)
    }

    private enum Item {
        case layer(RawLayer)
        case group(RawLayer, [Item])
    }

    private static func assemble(_ raw: [RawLayer], into records: inout [ProjectLayerRecord],
                                 images: inout [UUID: ImportedImage], masks: inout [UUID: ImportedImage],
                                 pixelsUsed: inout Int, canvas: CGSize) throws {
        var stack: [[Item]] = [[]]
        for layer in raw {
            switch layer.section {
            case .divider:
                stack.append([])
            case .folder:
                let children = stack.popLast() ?? []
                if stack.isEmpty { stack.append([]) }
                stack[stack.count - 1].append(.group(layer, children))
            case .none:
                if stack.isEmpty { stack.append([]) }
                stack[stack.count - 1].append(.layer(layer))
            }
        }
        while stack.count > 1 {
            let leftover = stack.removeLast()
            stack[stack.count - 1].append(contentsOf: leftover)
        }
        var clipped: [UUID: Bool] = [:]
        try flatten(stack.first ?? [], parent: nil, canvas: canvas, into: &records, images: &images, masks: &masks,
                    pixelsUsed: &pixelsUsed, clipped: &clipped)
        applyClipping(to: &records, clipped: clipped)
    }

    private static func flatten(_ items: [Item], parent: UUID?, canvas: CGSize,
                                into records: inout [ProjectLayerRecord], images: inout [UUID: ImportedImage],
                                masks: inout [UUID: ImportedImage], pixelsUsed: inout Int, clipped: inout [UUID: Bool]) throws {
        for item in items {
            switch item {
            case .layer(let raw):
                try append(raw, parent: parent, isGroup: false, canvas: canvas, into: &records, images: &images, masks: &masks,
                           pixelsUsed: &pixelsUsed, clipped: &clipped)
            case .group(let raw, let children):
                let id = try append(raw, parent: parent, isGroup: true, canvas: canvas, into: &records, images: &images, masks: &masks,
                                    pixelsUsed: &pixelsUsed, clipped: &clipped)
                try flatten(children, parent: id, canvas: canvas, into: &records, images: &images, masks: &masks,
                            pixelsUsed: &pixelsUsed, clipped: &clipped)
            }
        }
    }

    @discardableResult
    private static func append(_ raw: RawLayer, parent: UUID?, isGroup: Bool, canvas: CGSize,
                               into records: inout [ProjectLayerRecord], images: inout [UUID: ImportedImage],
                               masks: inout [UUID: ImportedImage], pixelsUsed: inout Int, clipped: inout [UUID: Bool]) throws -> UUID {
        let id = UUID()
        var transform: LayerTransform
        var imageFile: String?
        if isGroup || raw.adjustment != nil {
            transform = LayerTransform(origin: .zero, size: canvas)
        } else if let pixels = raw.pixels, pixels.count > 0 {
            try checkSize(width: pixels.width, height: pixels.height, used: &pixelsUsed)
            images[id] = try PSDPixels.imported(pixels, name: raw.name)
            imageFile = "\(id.uuidString).png"
            transform = LayerTransform(origin: CGPoint(x: raw.left, y: raw.top),
                                       size: CGSize(width: pixels.width, height: pixels.height))
        } else {
            let width = max(1, raw.width == 0 ? Int(canvas.width) : raw.width)
            let height = max(1, raw.height == 0 ? Int(canvas.height) : raw.height)
            transform = LayerTransform(origin: CGPoint(x: raw.left, y: raw.top), size: CGSize(width: width, height: height))
        }
        var maskFile: String?
        var maskEnabled: Bool?
        var maskPlacement: LayerTransform?
        if let info = raw.mask, let plane = raw.maskPlane, info.width > 0, info.height > 0 {
            var used = 0
            try checkSize(width: info.width, height: info.height, used: &used)
            masks[id] = try PSDPixels.mask(plane, width: info.width, height: info.height)
            maskFile = "\(id.uuidString).mask.png"
            maskEnabled = !info.disabled
            var origin = CGPoint(x: info.left, y: info.top)
            if info.relative { origin.x += CGFloat(raw.left); origin.y += CGFloat(raw.top) }
            let placement = LayerTransform(origin: origin, size: CGSize(width: info.width, height: info.height))
            if placement.origin != transform.origin || placement.size != transform.size {
                maskPlacement = placement
            }
        }
        let opacity = isGroup ? 1 : min(1, max(0, raw.opacity))
        let blend = isGroup ? LayerBlendMode.normal : raw.blend
        records.append(ProjectLayerRecord(id: id, name: raw.name, isVisible: !raw.hidden, transform: transform,
            imageFile: imageFile, parentID: parent, isGroup: isGroup, opacity: opacity, blendMode: blend,
            maskFile: maskFile, maskEnabled: maskEnabled, adjustment: isGroup ? nil : raw.adjustment,
            maskPlacement: maskPlacement, maskLinked: maskFile == nil ? nil : true))
        clipped[id] = raw.clipped
        return id
    }

    private static func applyClipping(to records: inout [ProjectLayerRecord], clipped: [UUID: Bool]) {
        let groups = Dictionary(grouping: records.indices, by: { records[$0].parentID })
        for indices in groups.values {
            var base: UUID?
            for index in indices {
                if records[index].isGroup == true {
                    base = nil
                    continue
                }
                if clipped[records[index].id] == true {
                    if let base, let source = records.first(where: { $0.id == base }),
                       source.isGroup != true, source.adjustment == nil {
                        records[index].maskSourceID = base
                    }
                } else {
                    base = records[index].id
                }
            }
        }
    }

    private static func checkSize(width: Int, height: Int, used: inout Int) throws {
        guard (0...30_000).contains(width), (0...30_000).contains(height) else { throw PSDError.tooLarge }
        if width == 0 || height == 0 { return }
        guard width * height <= 100_000_000 - used else { throw PSDError.tooLarge }
        used += width * height
    }

    private static func readU16(_ data: Data) -> UInt16 {
        UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }
    private static func readU32(_ data: Data) -> UInt32 {
        UInt32(data[data.startIndex]) << 24 | UInt32(data[data.startIndex + 1]) << 16
            | UInt32(data[data.startIndex + 2]) << 8 | UInt32(data[data.startIndex + 3])
    }

    private static func parseLevels(_ data: Data) -> LayerAdjustment? {
        let cursor = PSDCursor(data)
        guard (try? cursor.u16()) != nil else { return nil }
        var settings = LevelsSettings()
        for i in 0..<4 {
            guard let black = try? cursor.u16(), let white = try? cursor.u16(),
                  let outBlack = try? cursor.u16(), let outWhite = try? cursor.u16(),
                  let gamma = try? cursor.u16() else { return nil }
            var range = LevelRange()
            range.black = Double(black)
            range.white = Double(white)
            range.outputBlack = Double(outBlack)
            range.outputWhite = Double(outWhite)
            range.gamma = Double(gamma) / 100
            settings.ranges[i] = range.normalized
        }
        var adjustment = LayerAdjustment(kind: .levels)
        adjustment.levels = settings
        return adjustment.isValid ? adjustment : nil
    }

    private static func parseCurves(_ data: Data) -> LayerAdjustment? {
        let cursor = PSDCursor(data)
        guard let version = try? cursor.u16() else { return nil }
        var settings = CurvesSettings()
        let count: Int
        var mask = 0
        if version == 4 {
            count = Int((try? cursor.u16()) ?? 0)
        } else {
            mask = Int((try? cursor.u16()) ?? 0)
            count = 0
        }
        func readCurve() -> [CurvePoint]? {
            guard let n = try? cursor.u16(), (2...19).contains(Int(n)) else { return nil }
            var points: [CurvePoint] = []
            for _ in 0..<Int(n) {
                guard let output = try? cursor.u16(), let input = try? cursor.u16() else { return nil }
                points.append(CurvePoint(x: Double(input), y: Double(output)))
            }
            return points
        }
        if version == 4 {
            for i in 0..<min(count, 4) {
                if let points = readCurve() { settings.channels[i] = points }
            }
        } else {
            for i in 0..<4 where (mask & (1 << i)) != 0 {
                if let points = readCurve() { settings.channels[i] = points }
            }
        }
        var adjustment = LayerAdjustment(kind: .curves)
        adjustment.curves = settings
        return adjustment.isValid ? adjustment : nil
    }

    private static func parseHue(_ data: Data) -> LayerAdjustment? {
        let cursor = PSDCursor(data)
        guard let _ = try? cursor.u16(), let colorize = try? cursor.u8() else { return nil }
        _ = try? cursor.u8()
        func triplet() -> (Double, Double, Double)? {
            guard let h = try? cursor.i16(), let s = try? cursor.i16(), let l = try? cursor.i16() else { return nil }
            return (Double(h), Double(s), Double(l))
        }
        guard let colorizeValues = triplet(), let master = triplet() else { return nil }
        var settings = HueSaturationSettings()
        settings.colorize = colorize != 0
        if settings.colorize {
            var hue = colorizeValues.0
            if hue < 0 { hue += 360 }
            settings.adjustments[.master] = RangeAdjustment(hue: hue, saturation: colorizeValues.1, lightness: colorizeValues.2)
        } else {
            settings.adjustments[.master] = RangeAdjustment(hue: master.0, saturation: master.1, lightness: master.2)
            let ranges: [ColorRange] = [.reds, .yellows, .greens, .cyans, .blues, .magentas]
            for range in ranges {
                _ = try? cursor.i16(); _ = try? cursor.i16(); _ = try? cursor.i16(); _ = try? cursor.i16()
                if let values = triplet() {
                    settings.adjustments[range] = RangeAdjustment(hue: values.0, saturation: values.1, lightness: values.2)
                }
            }
        }
        var adjustment = LayerAdjustment(kind: .hsv)
        adjustment.hsvSettings = settings
        adjustment.hue = settings.adjustments[.master]?.hue ?? 0
        adjustment.saturation = settings.adjustments[.master]?.saturation ?? 0
        adjustment.lightness = settings.adjustments[.master]?.lightness ?? 0
        adjustment.colorize = settings.colorize
        return adjustment.isValid ? adjustment : nil
    }
}
