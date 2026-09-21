import CoreGraphics
import Foundation

/// Reads Photoshop `.psd` files from Adobe’s *Photoshop File Formats Specification*
/// (2019 HTML edition: File Header, Color Mode Data, Image Resources, Layer and
/// Mask Information, Image Data). Original implementation of the 8BPS header,
/// layer records, PackBits, and additional layer info. Not copied, transcribed,
/// or adapted from GIMP, psd-tools, or any other GPL-licensed PSD reader.
nonisolated enum PSDReader {
    static func matches(_ url: URL) -> Bool {
        matches(magicOf: url)
    }

    private static func matches(magicOf url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("8BPS".utf8)
    }

    static func matches(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data("8BPS".utf8)
    }

    static func read(from url: URL, remainingPixels: Int = 100_000_000) throws -> PSDDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try read(data, remainingPixels: remainingPixels)
    }

    static func read(_ data: Data, remainingPixels: Int = 100_000_000) throws -> PSDDocument {
        var cursor = PSDCursor(data: data)
        guard try cursor.string(4) == "8BPS" else { throw ImageImportError.unreadable }
        let version = try cursor.u16()
        guard version == 1 else { throw PSDError.unsupportedVersion }
        try cursor.skip(6)
        _ = try cursor.u16()
        let canvasHeight = Int(try cursor.u32())
        let canvasWidth = Int(try cursor.u32())
        let depth = try cursor.u16()
        let mode = try cursor.u16()
        guard (1...30_000).contains(canvasWidth), (1...30_000).contains(canvasHeight),
              canvasWidth * canvasHeight <= 100_000_000 else {
            throw ImageImportError.tooLarge
        }
        guard depth == 8 else { throw PSDError.unsupportedDepth }
        guard mode == 3 else { throw PSDError.unsupportedColorMode }
        try cursor.skip(Int(try cursor.u32()))
        let resourcesLength = Int(try cursor.u32())
        let resourcesEnd = cursor.offset + resourcesLength
        var resolution = 72.0
        while cursor.offset + 12 <= resourcesEnd {
            let signature = try cursor.string(4)
            guard signature == "8BIM" else { break }
            let id = try cursor.u16()
            let nameLength = Int(try cursor.u8())
            try cursor.skip(nameLength)
            if (nameLength + 1) % 2 == 1 { try cursor.skip(1) }
            let length = Int(try cursor.u32())
            let dataStart = cursor.offset
            if id == 1005, length >= 4 {
                resolution = Double(try cursor.u32()) / 65536
                if !resolution.isFinite || resolution < 1 { resolution = 72 }
                resolution = min(9600, max(1, resolution))
            }
            cursor.offset = dataStart + length
            if length % 2 == 1 { try cursor.skip(1) }
        }
        cursor.offset = resourcesEnd
        let layerSection = Int(try cursor.u32())
        let layerSectionEnd = cursor.offset + layerSection
        guard layerSection >= 4 else {
            return PSDDocument(width: canvasWidth, height: canvasHeight, resolution: resolution, layers: [])
        }
        let layerInfoLength = Int(try cursor.u32())
        _ = layerInfoLength
        let rawCount = try cursor.i16()
        let count = abs(Int(rawCount))
        guard count <= 10_000 else { throw ImageImportError.tooLarge }
        var raw = [RawLayer]()
        raw.reserveCapacity(count)
        for _ in 0..<count { raw.append(try readRecord(&cursor)) }
        var usedPixels = 0
        for index in raw.indices {
            try decodeChannels(&cursor, layer: &raw[index], remainingPixels: remainingPixels - usedPixels)
            if let image = raw[index].image { usedPixels += image.width * image.height }
        }
        cursor.offset = layerSectionEnd
        return PSDDocument(width: canvasWidth, height: canvasHeight, resolution: resolution,
                           layers: try assemble(raw, canvas: CGSize(width: canvasWidth, height: canvasHeight),
                                                remainingPixels: remainingPixels - usedPixels))
    }

    private struct RawLayer {
        var name = ""
        var top = 0, left = 0, bottom = 0, right = 0
        var opacity: UInt8 = 255
        var fill: UInt8 = 255
        var clipping = false
        var hidden = false
        var blendKey = "norm"
        var channels: [(id: Int, length: Int)] = []
        var extra: [String: Data] = [:]
        var maskTop = 0, maskLeft = 0, maskBottom = 0, maskRight = 0
        var maskDefault: UInt8 = 255
        var maskDisabled = false
        var maskLinked = true
        var maskFromRender = false
        var hasMask = false
        var section: Int?
        var image: CGImage?
        var maskImage: CGImage?
    }

    private static func readRecord(_ cursor: inout PSDCursor) throws -> RawLayer {
        var layer = RawLayer()
        layer.top = Int(try cursor.i32())
        layer.left = Int(try cursor.i32())
        layer.bottom = Int(try cursor.i32())
        layer.right = Int(try cursor.i32())
        let channelCount = Int(try cursor.u16())
        guard channelCount <= 56 else { throw ImageImportError.tooLarge }
        for _ in 0..<channelCount {
            let id = Int(try cursor.i16())
            let length = Int(try cursor.u32())
            layer.channels.append((id, length))
        }
        guard try cursor.string(4) == "8BIM" else { throw PSDError.truncated }
        layer.blendKey = try cursor.string(4)
        layer.opacity = try cursor.u8()
        layer.clipping = try cursor.u8() != 0
        let flags = try cursor.u8()
        layer.hidden = (flags & 2) != 0
        try cursor.skip(1)
        let extraLength = Int(try cursor.u32())
        let extraEnd = cursor.offset + extraLength
        let maskLength = Int(try cursor.u32())
        let maskEnd = cursor.offset + maskLength
        if maskLength >= 20 {
            layer.hasMask = true
            layer.maskTop = Int(try cursor.i32())
            layer.maskLeft = Int(try cursor.i32())
            layer.maskBottom = Int(try cursor.i32())
            layer.maskRight = Int(try cursor.i32())
            layer.maskDefault = try cursor.u8()
            let maskFlags = try cursor.u8()
            layer.maskDisabled = (maskFlags & 2) != 0
            layer.maskLinked = (maskFlags & 1) == 0
            layer.maskFromRender = (maskFlags & 8) != 0
        }
        cursor.offset = maskEnd
        let ranges = Int(try cursor.u32())
        try cursor.skip(ranges)
        let nameCount = Int(try cursor.u8())
        let nameBytes = try cursor.bytes(nameCount)
        layer.name = String(bytes: nameBytes, encoding: .macOSRoman) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "Layer"
        let namePad = (4 - ((nameCount + 1) % 4)) % 4
        try cursor.skip(namePad)
        while cursor.offset + 12 <= extraEnd {
            let signature = try cursor.string(4)
            guard signature == "8BIM" || signature == "8B64" else { break }
            let key = try cursor.string(4)
            let length: Int
            if signature == "8B64" {
                guard cursor.offset + 8 <= extraEnd else { break }
                let raw = UInt64(try cursor.u32()) << 32 | UInt64(try cursor.u32())
                guard raw <= UInt64(Int.max) else { throw ImageImportError.tooLarge }
                length = Int(raw)
            } else {
                length = Int(try cursor.u32())
            }
            let payload = try cursor.bytes(length)
            if length % 2 == 1 { try cursor.skip(1) }
            layer.extra[key] = payload
            if key == "luni", let unicode = unicodeName(payload) { layer.name = unicode }
            if key == "iOpa", let fill = payload.first { layer.fill = fill }
            if key == "lsct" || key == "lsdk", payload.count >= 4 {
                layer.section = Int(u32(payload, 0))
            }
        }
        cursor.offset = extraEnd
        return layer
    }

    private static func unicodeName(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let count = Int(u32(data, 0))
        guard count > 0, data.count >= 4 + count * 2 else { return nil }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for i in 0..<count {
            let hi = data[4 + i * 2], lo = data[5 + i * 2]
            units.append(UInt16(hi) << 8 | UInt16(lo))
        }
        return String(utf16CodeUnits: units, count: count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Transparency, R, G, B, and the user mask. Spot and other extra IDs are skipped before decode.
    private static let unpackedChannelIDs: Set<Int> = [-1, 0, 1, 2, -2]

    private static func decodeChannels(_ cursor: inout PSDCursor, layer: inout RawLayer, remainingPixels: Int) throws {
        var planes: [Int: [UInt8]] = [:]
        let width = max(0, layer.right - layer.left)
        let height = max(0, layer.bottom - layer.top)
        let maskWidth = max(0, layer.maskRight - layer.maskLeft)
        let maskHeight = max(0, layer.maskBottom - layer.maskTop)
        let budget = max(0, remainingPixels)
        if width > 0, height > 0 {
            guard width <= 30_000, height <= 30_000, width * height <= budget else { throw ImageImportError.tooLarge }
        }
        if layer.hasMask, maskWidth > 0, maskHeight > 0 {
            guard maskWidth <= 30_000, maskHeight <= 30_000, maskWidth * maskHeight <= budget else {
                throw ImageImportError.tooLarge
            }
        }
        for channel in layer.channels {
            let start = cursor.offset
            defer { cursor.offset = start + max(0, channel.length) }
            guard unpackedChannelIDs.contains(channel.id), channel.length >= 2 else { continue }
            let compression = Int(try cursor.u16())
            let payload = try cursor.bytes(channel.length - 2)
            let isMask = channel.id == -2
            let w = isMask ? maskWidth : width
            let h = isMask ? maskHeight : height
            if w > 0, h > 0 {
                planes[channel.id] = try PSDChannelCoder.decode(compression: compression, width: w, height: h, data: payload)
            }
        }
        if layer.hasMask, maskWidth > 0, maskHeight > 0, let gray = planes[-2], gray.count >= maskWidth * maskHeight {
            layer.maskImage = try PSDChannelCoder.maskImage(width: maskWidth, height: maskHeight, gray: gray)
        }
        guard width > 0, height > 0 else { return }
        let opaque = [UInt8](repeating: 255, count: width * height)
        let black = [UInt8](repeating: 0, count: width * height)
        let red = planes[0] ?? black
        let green = planes[1] ?? black
        let blue = planes[2] ?? black
        let alpha = planes[-1] ?? opaque
        guard red.count >= width * height, green.count >= width * height, blue.count >= width * height, alpha.count >= width * height else {
            throw PSDError.truncated
        }
        layer.image = try PSDChannelCoder.rgbaImage(width: width, height: height, red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func assemble(_ raw: [RawLayer], canvas: CGSize, remainingPixels: Int) throws -> [PSDRecord] {
        var result: [PSDRecord] = []
        var groups: [UUID] = []
        var remaining = max(0, remainingPixels)
        for layer in raw {
            // Photoshop stores groups bottom-to-top: type 3 divider, then children, then the folder (type 1/2).
            if layer.section == 3 {
                groups.append(UUID())
                continue
            }
            let isGroup = layer.section == 1 || layer.section == 2
            let id = isGroup ? (groups.popLast() ?? UUID()) : UUID()
            var record = PSDRecord(id: id, name: layer.name.isEmpty ? "Layer" : layer.name)
            record.parentID = groups.last
            record.isGroup = isGroup
            record.isVisible = !layer.hidden
            record.blendKey = isGroup && (layer.blendKey == "pass" || layer.blendKey == "norm") ? "pass" : layer.blendKey
            record.clipping = layer.clipping
            record.kind = kind(layer, isGroup: isGroup)
            let hasEffects = record.kind == .effects || layer.extra.keys.contains(where: { ["lfx2", "lrFX", "lmfx"].contains($0) })
            if hasEffects, layer.fill != 255 {
                record.opacity = Double(layer.opacity) / 255
            } else {
                record.opacity = (Double(layer.opacity) / 255) * (Double(layer.fill) / 255)
            }
            record.bounds = isGroup
                ? CGRect(origin: .zero, size: canvas)
                : CGRect(x: layer.left, y: layer.top,
                         width: max(0, layer.right - layer.left), height: max(0, layer.bottom - layer.top))
            record.image = isGroup ? nil : layer.image
            if !isGroup, let live = try PSDVector.live(extra: layer.extra, canvas: canvas, remainingPixels: remaining) {
                record.image = live.image
                record.bounds = live.bounds
                record.shape = live.style
                record.shapeNotes = live.notes
                record.kind = .vector
                remaining = max(0, remaining - live.image.width * live.image.height)
            } else if record.image == nil, !isGroup, let raster = try PSDVector.raster(extra: layer.extra, canvas: canvas, remainingPixels: remaining) {
                record.image = raster.image
                record.bounds = raster.bounds
                record.kind = .vector
                remaining = max(0, remaining - raster.image.width * raster.image.height)
            }
            record.mask = layer.maskFromRender ? nil : layer.maskImage
            record.maskEnabled = !layer.maskDisabled
            record.maskLinked = layer.maskLinked
            if !isGroup { record.adjustment = PSDAdjustments.parse(layer.extra) }
            if record.adjustment != nil { record.kind = .adjustment }
            result.append(record)
        }
        guard groups.isEmpty else { throw PSDError.truncated }
        return result
    }

    private static func kind(_ layer: RawLayer, isGroup: Bool) -> PSDLayerKind {
        if isGroup { return .group }
        if layer.extra.keys.contains(where: { ["TySh", "tySh", "txt2"].contains($0) }) { return .text }
        if layer.extra.keys.contains(where: { ["vmsk", "vsms", "vogk"].contains($0) }) { return .vector }
        if layer.extra.keys.contains(where: { ["SoLd", "SoLE"].contains($0) }) { return .smartObject }
        if layer.extra.keys.contains(where: { ["lfx2", "lrFX", "lmfx"].contains($0) }) { return .effects }
        if layer.extra.keys.contains(where: { Self.adjustmentKeys.contains($0) }) { return .adjustment }
        return .raster
    }

    static let adjustmentKeys: Set<String> = [
        "levl", "curv", "hue2", "hue ", "expA", "grdm", "brit", "blnc", "nvrt",
        "thrs", "post", "mixr", "selc", "blwh", "phfl", "vibA"
    ]

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
}

nonisolated private struct PSDCursor: Sendable {
    let data: Data
    var offset = 0

    mutating func need(_ count: Int) throws {
        guard offset >= 0, offset + count <= data.count else { throw PSDError.truncated }
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0 else { throw PSDError.truncated }
        try need(count)
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ count: Int) throws -> Data {
        try need(count)
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func string(_ count: Int) throws -> String {
        let bytes = try bytes(count)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

nonisolated enum PSDAdjustments {
    static func parse(_ extra: [String: Data]) -> LayerAdjustment? {
        if let data = extra["levl"] { return levels(data) }
        if let data = extra["curv"] { return curves(data) }
        if let data = extra["hue2"] ?? extra["hue "] { return hue(data) }
        return nil
    }

    private static func levels(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 292 else { return nil }
        var settings = LevelsSettings()
        for channel in 0..<4 {
            let base = 2 + channel * 10
            let inputBlack = Double(u16(data, base))
            let inputWhite = Double(u16(data, base + 2))
            let outputBlack = Double(u16(data, base + 4))
            let outputWhite = Double(u16(data, base + 6))
            let gamma = Double(u16(data, base + 8)) / 256
            settings.ranges[channel] = LevelRange(black: inputBlack, gamma: gamma, white: inputWhite,
                                                  outputBlack: outputBlack, outputWhite: outputWhite).normalized
        }
        return LayerAdjustment(kind: .levels, levels: settings)
    }

    private static func curves(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 5 else { return nil }
        var offset = 0
        if data[offset] == 0 { offset += 1 }
        guard offset + 2 <= data.count else { return nil }
        let version = u16(data, offset)
        offset += 2
        guard version == 1 || version == 4 else { return nil }
        guard offset + 2 <= data.count else { return nil }
        let count = Int(u16(data, offset))
        offset += 2
        var settings = CurvesSettings()
        for channel in 0..<min(4, count) {
            guard offset + 2 <= data.count else { return nil }
            let points = Int(u16(data, offset))
            offset += 2
            var curve = [CurvePoint]()
            for _ in 0..<points {
                guard offset + 4 <= data.count else { return nil }
                let output = Double(u16(data, offset))
                let input = Double(u16(data, offset + 2))
                offset += 4
                curve.append(CurvePoint(x: min(255, max(0, input)), y: min(255, max(0, output))))
            }
            if curve.count >= 2 {
                curve.sort { $0.x < $1.x }
                if curve.first?.x != 0 { curve.insert(CurvePoint(x: 0, y: curve.first!.y), at: 0) }
                if curve.last?.x != 255 { curve.append(CurvePoint(x: 255, y: curve.last!.y)) }
                settings.channels[channel] = curve
            }
        }
        guard settings.isValid else { return nil }
        return LayerAdjustment(kind: .curves, curves: settings)
    }

    private static func hue(_ data: Data) -> LayerAdjustment? {
        guard data.count >= 4 else { return nil }
        let colorize = data[2] != 0
        var settings = HueSaturationSettings(colorize: colorize)
        let ranges = [ColorRange.master, .reds, .yellows, .greens, .cyans, .blues, .magentas]
        var offset = 4
        for range in ranges {
            guard offset + 6 <= data.count else { break }
            let hue = i16(data, offset)
            let saturation = i16(data, offset + 2)
            let lightness = i16(data, offset + 4)
            offset += 6
            settings.adjustments[range] = RangeAdjustment(hue: Double(hue), saturation: Double(saturation), lightness: Double(lightness))
        }
        return LayerAdjustment(kind: .hsv, hsvSettings: settings)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func i16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }
}
