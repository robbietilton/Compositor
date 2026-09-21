import Foundation

/// Parsed structures of one PSD file: header, layer records (with tagged-block facts),
/// absolute channel-data offsets, and the layer tree the records encode.
nonisolated struct PSDHeader {
    let width: Int
    let height: Int
    let channels: Int
    let depth: Int
    let colorMode: Int
}

nonisolated struct PSDRect: Equatable {
    var top: Int, left: Int, bottom: Int, right: Int
    var width: Int { max(0, right - left) }
    var height: Int { max(0, bottom - top) }
    var isEmpty: Bool { width == 0 || height == 0 }
    /// Pixel count, nil when the sides overflow multiplication. Untrusted rects span nearly
    /// the whole I32 range per side, and any rect that overflows sits far past every import
    /// budget — callers treat nil as over-budget instead of trapping on the multiply.
    var area: Int? {
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : product
    }
}

nonisolated struct PSDChannelInfo {
    let id: Int16
    let length: UInt32
    /// Absolute file offset of the channel's compression code, assigned on the channel-data walk.
    var offset: UInt64 = 0
    var isEmpty: Bool { length <= 2 }
}

nonisolated struct PSDMaskInfo {
    var rect: PSDRect
    var background: UInt8
    var isDisabled: Bool
}

nonisolated struct PSDLayerRecord {
    var rect: PSDRect
    var channels: [PSDChannelInfo]
    var blendKey: String
    var opacity: UInt8
    var isClipped: Bool
    var isHidden: Bool
    var name: String
    var mask: PSDMaskInfo?
    /// lsct divider type: 1/2 = group header, 3 = group bottom seal; nil = plain layer.
    var divider: Int?
    /// The blend key inside the lsct block ("pass" marks a pass-through group).
    var groupBlendKey: String?
    var artboardRect: PSDRect?
    var isGroup: Bool { divider == 1 || divider == 2 }
    var isSeal: Bool { divider == 3 }
    func channel(_ id: Int16) -> PSDChannelInfo? { channels.first { $0.id == id } }
    /// A layer is rasterizable when its RGB channels carry data: adjustment layers, fill layers
    /// and pure structure rows store length-2 placeholder channels instead.
    var hasPixels: Bool {
        [Int16(0), 1, 2].allSatisfy { channel($0)?.isEmpty == false }
    }
}

nonisolated final class PSDNode {
    enum Kind { case layer, group }
    let kind: Kind
    /// The record this node's facts come from: the layer itself, or a group's header (the
    /// row Photoshop shows, carrying the name, opacity, mask and artboard). The group's bottom
    /// seal only brackets the children and leaves no trace in the tree.
    var recordIndex: Int
    var children: [PSDNode] = []
    var passThrough = false
    var artboardRect: PSDRect?
    init(kind: Kind, recordIndex: Int) {
        self.kind = kind
        self.recordIndex = recordIndex
    }
}

nonisolated struct PSDDocument {
    let header: PSDHeader
    let records: [PSDLayerRecord]
    /// Absolute offset where the channel data area begins (right after the last layer record).
    let channelDataStart: UInt64
    let layerInfoEnd: UInt64
    let roots: [PSDNode]
}

nonisolated enum PSDReader {
    static func read(url: URL) throws -> PSDDocument {
        var reader = try PSDFileReader(url: url)
        let header = try readHeader(&reader)
        // Color Mode Data is empty for RGB; Image Resources is skipped wholesale.
        try reader.skip(UInt64(try reader.readU32()))
        try reader.skip(UInt64(try reader.readU32()))
        let layerAndMaskLength = try reader.readU32()
        // A zero-length Layer & Mask section (how Photoshop spells a layerless file) has no
        // Layer Info inside at all; the composite follows immediately.
        guard layerAndMaskLength > 0 else {
            return PSDDocument(header: header, records: [], channelDataStart: reader.offset,
                               layerInfoEnd: reader.offset, roots: [])
        }
        let layerAndMaskEnd = reader.offset + UInt64(layerAndMaskLength)
        let layerInfoLength = try reader.readU32()
        let layerInfoEnd = reader.offset + UInt64(layerInfoLength)
        // Photoshop spells a layerless file "Layer & Mask length 0"; some third-party writers
        // keep the section but give Layer Info a zero length. Either way the count field is
        // absent and no records follow, so the importer falls back to the composite.
        guard layerInfoLength > 0 else {
            return PSDDocument(header: header, records: [], channelDataStart: reader.offset,
                               layerInfoEnd: layerInfoEnd, roots: [])
        }
        let rawCount = try reader.readI16()
        let count = abs(Int(rawCount))
        var records = [PSDLayerRecord]()
        records.reserveCapacity(count)
        for index in 0..<count {
            records.append(try readLayerRecord(&reader, index: index))
        }
        // Records sit back to back; the channel data area follows the last one. Each channel
        // then advances by its listed length, with no per-channel padding.
        let channelDataStart = reader.offset
        var walk = channelDataStart
        for recordIndex in records.indices {
            for channelIndex in records[recordIndex].channels.indices {
                records[recordIndex].channels[channelIndex].offset = walk
                walk += UInt64(records[recordIndex].channels[channelIndex].length)
            }
        }
        guard walk <= layerInfoEnd else { throw PSDImportError.damaged("channel data overruns the layer section") }
        // Global layer mask info and global tagged blocks (including embedded smart-object
        // sources) hold nothing the importer needs; the layer section ends before the composite.
        guard layerInfoEnd <= layerAndMaskEnd else { throw PSDImportError.damaged("layer section overruns its bounds") }
        return PSDDocument(header: header, records: records, channelDataStart: channelDataStart,
                           layerInfoEnd: layerInfoEnd, roots: try buildTree(records))
    }

    static func readHeader(_ reader: inout PSDFileReader) throws -> PSDHeader {
        let signature = try reader.read(4)
        guard signature == PSDFormat.signature else { throw PSDImportError.unreadable }
        let version = try reader.readU16()
        if version == 2 { throw PSDImportError.psb }
        guard version == 1 else { throw PSDImportError.unreadable }
        try reader.skip(6)
        let channels = try reader.readU16()
        let height = try reader.readU32()
        let width = try reader.readU32()
        let depth = try reader.readU16()
        let colorMode = try reader.readU16()
        guard depth == 8 else { throw PSDImportError.depth(Int(depth)) }
        guard colorMode == 3 else { throw PSDImportError.colorMode(Int(colorMode)) }
        guard width > 0, height > 0 else { throw PSDImportError.damaged("the canvas has no size") }
        return PSDHeader(width: Int(width), height: Int(height), channels: Int(channels),
                         depth: Int(depth), colorMode: Int(colorMode))
    }

    private static func readLayerRecord(_ reader: inout PSDFileReader, index: Int) throws -> PSDLayerRecord {
        let rect = PSDRect(top: Int(try reader.readI32()), left: Int(try reader.readI32()),
                           bottom: Int(try reader.readI32()), right: Int(try reader.readI32()))
        let channelCount = Int(try reader.readU16())
        guard channelCount <= 56 else { throw PSDImportError.damaged("layer \(index) lists too many channels") }
        var channels = [PSDChannelInfo]()
        channels.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            let id = try reader.readI16()
            let length = try reader.readU32()
            channels.append(PSDChannelInfo(id: id, length: length))
        }
        let signature = try reader.readTag()
        guard signature == "8BIM" || signature == "8B64" else {
            throw PSDImportError.damaged("layer \(index) has no blend-mode signature")
        }
        let blendKey = try reader.readTag() ?? ""
        let opacity = try reader.readU8()
        let clipping = try reader.readU8()
        let flags = try reader.readU8()
        _ = try reader.readU8() // filler
        let extraLength = Int(try reader.readU32())
        let extraEnd = reader.offset + UInt64(extraLength)
        var record = PSDLayerRecord(rect: rect, channels: channels, blendKey: blendKey, opacity: opacity,
                                    isClipped: clipping == 1, isHidden: flags & 0x02 != 0,
                                    name: "Layer \(index + 1)", mask: nil, divider: nil,
                                    groupBlendKey: nil, artboardRect: nil)
        try readExtraData(&reader, recordIndex: index, extraEnd: extraEnd, into: &record)
        try reader.seek(to: extraEnd)
        return record
    }

    private static func readExtraData(_ reader: inout PSDFileReader, recordIndex: Int, extraEnd: UInt64,
                                      into record: inout PSDLayerRecord) throws {
        let maskLength = Int(try reader.readU32())
        if maskLength > 0 {
            let maskEnd = reader.offset + UInt64(maskLength)
            let rect = PSDRect(top: Int(try reader.readI32()), left: Int(try reader.readI32()),
                               bottom: Int(try reader.readI32()), right: Int(try reader.readI32()))
            let background = try reader.readU8()
            let flags = try reader.readU8()
            record.mask = PSDMaskInfo(rect: rect, background: background, isDisabled: flags & 0x02 != 0)
            try reader.seek(to: maskEnd) // The mask block pads to 4; real-mask fields (a -3 channel) are unused.
        }
        try reader.skip(UInt64(try reader.readU32())) // blending ranges
        // Pascal name, padded to 4; unreliable for non-ASCII names, so it is only a fallback.
        let nameLength = Int(try reader.readU8())
        let pascal = try reader.read(nameLength)
        try reader.skip(UInt64((4 - (1 + nameLength) % 4) % 4))
        if let decoded = String(bytes: pascal, encoding: .macOSRoman), !decoded.isEmpty {
            record.name = decoded
        }
        while reader.offset + 12 <= extraEnd {
            guard let signature = try reader.readTag(), signature == "8BIM" || signature == "8B64" else {
                throw PSDImportError.damaged("layer \(recordIndex) has a malformed tagged block")
            }
            let key = try reader.readTag() ?? ""
            let length = Int(try reader.readU32())
            guard reader.offset + UInt64(length) <= extraEnd else {
                throw PSDImportError.damaged("layer \(recordIndex) has an overlong tagged block")
            }
            let data = try reader.read(length)
            try reader.skip(UInt64(length % 2)) // tagged-block data pads to even, length includes it
            switch key {
            case "luni":
                if let name = decodeUnicodeName(data), !name.isEmpty { record.name = name }
            case "lsct":
                record.divider = data.count >= 4 ? Int(be32(data, 0)) : nil
                if data.count >= 12, String(bytes: data[4..<8], encoding: .ascii) == "8BIM" {
                    record.groupBlendKey = String(bytes: data[8..<12], encoding: .ascii)
                }
            case "artb", "artd", "abdd":
                record.artboardRect = PSDDescriptor.artboardRect(in: data)
            default:
                break // lyid, SoLd, TySh, SoCo and the rest carry nothing the importer needs.
            }
        }
    }

    /// luni: a U32 character count followed by UTF-16BE text — the only reliable source of
    /// non-ASCII layer names.
    private static func decodeUnicodeName(_ data: [UInt8]) -> String? {
        guard data.count >= 4 else { return nil }
        let characters = Int(be32(data, 0))
        let byteCount = min(characters * 2, data.count - 4)
        return String(bytes: data[4..<4 + byteCount], encoding: .utf16BigEndian)
    }

    private static func be32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    /// Records are stored bottom-up; a group is a bottom seal (lsct type 3) before its children
    /// and a header record (type 1/2, carrying the name) after them. The stack rebuilds that
    /// tree: the seal opens the group, the header closes it and becomes the node's record.
    static func buildTree(_ records: [PSDLayerRecord]) throws -> [PSDNode] {
        var stack = [PSDNode]()
        var roots = [PSDNode]()
        for (index, record) in records.enumerated() {
            if record.isSeal {
                stack.append(PSDNode(kind: .group, recordIndex: index))
            } else if record.isGroup {
                guard let opened = stack.popLast() else {
                    throw PSDImportError.damaged("a group header has no matching divider")
                }
                opened.recordIndex = index
                opened.passThrough = record.groupBlendKey == "pass"
                opened.artboardRect = record.artboardRect
                if let top = stack.last { top.children.append(opened) }
                else { roots.append(opened) }
            } else {
                let node = PSDNode(kind: .layer, recordIndex: index)
                if let top = stack.last { top.children.append(node) }
                else { roots.append(node) }
            }
        }
        guard stack.isEmpty else { throw PSDImportError.damaged("a group divider is never closed") }
        return roots
    }
}

/// Walks just enough of Photoshop's descriptor structure to pull `artboardRect` out of an
/// `artb` block: object values, lists, doubles, unit floats, strings, enums and integers.
/// Anything else aborts the walk, leaving the group a plain folder rather than an artboard.
nonisolated enum PSDDescriptor {
    static func artboardRect(in data: [UInt8]) -> PSDRect? {
        var cursor = 0
        // DescriptorBlock: U32 version (16), then name string, class ID, items.
        guard data.count >= 8, be32(data, &cursor) == 16 else { return nil }
        return findArtboardRect(data, &cursor)
    }

    private static func findArtboardRect(_ data: [UInt8], _ cursor: inout Int) -> PSDRect? {
        skipUnicodeString(data, &cursor)
        skipKey(data, &cursor)
        let itemCount = Int(be32(data, &cursor))
        for _ in 0..<itemCount {
            let key = readKey(data, &cursor)
            let type = tag(data, &cursor)
            if key == "artboardRect", type == "Objc" {
                return rectObject(data, &cursor)
            }
            guard skipValue(data, &cursor, type) else { return nil }
        }
        return nil
    }

    /// The artboardRect object: a nested descriptor whose four items are `Top ` (trailing
    /// space), `Left`, `Btom`, `Rght` doubles in layer-rect coordinates.
    private static func rectObject(_ data: [UInt8], _ cursor: inout Int) -> PSDRect? {
        skipUnicodeString(data, &cursor)
        skipKey(data, &cursor)
        let itemCount = Int(be32(data, &cursor))
        var values: [String: Double] = [:]
        for _ in 0..<itemCount {
            let key = readKey(data, &cursor)
            let type = tag(data, &cursor)
            switch type {
            case "doub": values[key] = beDouble(data, &cursor)
            case "UntF": cursor += 4; values[key] = beDouble(data, &cursor)
            default: guard skipValue(data, &cursor, type) else { return nil }
            }
        }
        guard let top = values["Top "], let left = values["Left"],
              let bottom = values["Btom"], let right = values["Rght"],
              let topSide = side(top), let leftSide = side(left),
              let bottomSide = side(bottom), let rightSide = side(right) else { return nil }
        return PSDRect(top: topSide, left: leftSide, bottom: bottomSide, right: rightSide)
    }

    /// One artboard side, nil for a value no rect could hold (NaN, infinities, anything past
    /// the I32 coordinate range) — a damaged descriptor yields no artboard, not a crash.
    private static func side(_ value: Double) -> Int? {
        guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
        return Int(value.rounded())
    }

    private static func skipValue(_ data: [UInt8], _ cursor: inout Int, _ type: String, depth: Int = 0) -> Bool {
        guard depth <= 64 else { return false } // crafted nesting must not exhaust the stack
        switch type {
        case "Objc", "GlbO":
            skipUnicodeString(data, &cursor); skipKey(data, &cursor)
            let count = Int(be32(data, &cursor))
            for _ in 0..<count {
                skipKey(data, &cursor)
                guard skipValue(data, &cursor, tag(data, &cursor), depth: depth + 1) else { return false }
            }
        case "VlLs":
            let count = Int(be32(data, &cursor))
            for _ in 0..<count { guard skipValue(data, &cursor, tag(data, &cursor), depth: depth + 1) else { return false } }
        case "doub": cursor += 8
        case "UntF": cursor += 12
        case "TEXT": skipUnicodeString(data, &cursor)
        case "enum": skipKey(data, &cursor); skipKey(data, &cursor)
        case "long": cursor += 4
        case "comp": cursor += 8
        case "bool": cursor += 1
        case "type", "GlbC": skipUnicodeString(data, &cursor); skipKey(data, &cursor)
        case "alis", "tdta", "ObAr":
            cursor += Int(be32(data, &cursor))
        default:
            return false // Untyped or undocumented: refuse to guess sizes.
        }
        return cursor <= data.count
    }

    // MARK: primitives

    /// Reads a big-endian U32; past the end, saturates and parks the cursor outside the data.
    private static func be32(_ data: [UInt8], _ cursor: inout Int) -> UInt32 {
        guard cursor + 4 <= data.count else { cursor = data.count + 1; return 0 }
        let value = UInt32(data[cursor]) << 24 | UInt32(data[cursor + 1]) << 16
            | UInt32(data[cursor + 2]) << 8 | UInt32(data[cursor + 3])
        cursor += 4
        return value
    }
    private static func beDouble(_ data: [UInt8], _ cursor: inout Int) -> Double {
        guard cursor + 8 <= data.count else { cursor = data.count + 1; return 0 }
        var bits: UInt64 = 0
        for offset in 0..<8 { bits = bits << 8 | UInt64(data[cursor + offset]) }
        cursor += 8
        return Double(bitPattern: bits)
    }
    private static func tag(_ data: [UInt8], _ cursor: inout Int) -> String {
        guard cursor + 4 <= data.count else { cursor = data.count + 1; return "" }
        let value = String(bytes: data[cursor..<cursor + 4], encoding: .ascii) ?? ""
        cursor += 4
        return value
    }
    /// Descriptor keys: a U32 byte length, or 0 meaning the next four bytes are the key.
    private static func readKey(_ data: [UInt8], _ cursor: inout Int) -> String {
        let length = Int(be32(data, &cursor))
        let count = length == 0 ? 4 : length
        guard cursor + count <= data.count else { cursor = data.count + 1; return "" }
        let value = String(bytes: data[cursor..<cursor + count], encoding: .ascii) ?? ""
        cursor += count
        return value
    }
    private static func skipKey(_ data: [UInt8], _ cursor: inout Int) { _ = readKey(data, &cursor) }
    private static func skipUnicodeString(_ data: [UInt8], _ cursor: inout Int) {
        let characters = Int(be32(data, &cursor))
        cursor += characters * 2
    }
}
