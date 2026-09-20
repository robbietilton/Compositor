import Compression
import Foundation

nonisolated enum PSDError: LocalizedError, Equatable {
    case invalid, unsupportedVersion, unsupportedColorMode, unsupportedDepth, unsupportedCompression, tooLarge, encode
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid Photoshop document, or it is damaged."
        case .unsupportedVersion: "Photoshop Large Document (PSB) files are not supported."
        case .unsupportedColorMode: "This Photoshop file uses a color mode Compositor doesn’t open. Save it as 8-bit RGB or Grayscale in Photoshop and try again."
        case .unsupportedDepth: "This Photoshop file is not 8-bit. Save it as 8-bit RGB or Grayscale in Photoshop and try again."
        case .unsupportedCompression: "This Photoshop file uses channel compression Compositor doesn’t open."
        case .tooLarge: "This Photoshop file exceeds the supported canvas, layer, file-size, or 100-megapixel image limit."
        case .encode: "The Photoshop document could not be written."
        }
    }
}

nonisolated enum PSDFourCC {
    static let file: UInt32 = 0x3842_5053 // 8BPS
    static let resource: UInt32 = 0x3842_494D // 8BIM
    static let resource64: UInt32 = 0x3842_3634 // 8B64
    static func code(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in text.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }
}

nonisolated final class PSDCursor {
    let data: Data
    private let raw: [UInt8]
    var offset = 0
    var remaining: Int { raw.count - offset }
    init(_ data: Data) {
        self.data = data
        self.raw = [UInt8](data)
    }

    func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw PSDError.invalid }
        offset += count
    }
    func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw PSDError.invalid }
        let slice = raw[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }
    func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw PSDError.invalid }
        let value = raw[offset]
        offset += 1
        return value
    }
    func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw PSDError.invalid }
        let value = UInt16(raw[offset]) << 8 | UInt16(raw[offset + 1])
        offset += 2
        return value
    }
    func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw PSDError.invalid }
        let value = UInt32(raw[offset]) << 24 | UInt32(raw[offset + 1]) << 16
            | UInt32(raw[offset + 2]) << 8 | UInt32(raw[offset + 3])
        offset += 4
        return value
    }
    func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    func fourCC() throws -> UInt32 { try u32() }
    func pascal(paddedTo alignment: Int) throws -> String {
        let start = offset
        let count = Int(try u8())
        let bytes = try bytes(count)
        let raw = start + 1 + count
        if alignment > 1 {
            let padded = ((raw - start + alignment - 1) / alignment) * alignment
            try skip(padded - (raw - start))
        }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(bytes: bytes, encoding: .ascii) ?? ""
    }
    func unicode() throws -> String {
        let count = Int(try u32())
        guard count >= 0, remaining >= count * 2 else { throw PSDError.invalid }
        var units = [UInt16]()
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

nonisolated struct PSDBuffer {
    private(set) var data = Data()
    var count: Int { data.count }
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func fourCC(_ value: UInt32) { u32(value) }
    mutating func fourCC(_ text: String) { u32(PSDFourCC.code(text)) }
    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func pascal(_ text: String, paddedTo alignment: Int) {
        let bytes = Array(text.utf8.prefix(255))
        let start = data.count
        u8(UInt8(bytes.count))
        append(bytes)
        let extra = (alignment - (data.count - start) % alignment) % alignment
        if extra > 0 { data.append(contentsOf: repeatElement(0, count: extra)) }
    }
    mutating func unicode(_ text: String) {
        let units = Array(text.utf16)
        u32(UInt32(units.count + 1))
        for unit in units { u16(unit) }
        u16(0)
    }
    mutating func patchU32(at index: Int, _ value: UInt32) {
        data[index] = UInt8(value >> 24)
        data[index + 1] = UInt8((value >> 16) & 0xff)
        data[index + 2] = UInt8((value >> 8) & 0xff)
        data[index + 3] = UInt8(value & 0xff)
    }
}

nonisolated enum PSDPackBits {
    static func pack(_ row: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = row.startIndex
        let end = row.endIndex
        while i < end {
            if i + 1 < end, row[i] == row[i + 1] {
                var count = 2
                while i + count < end, count < 128, row[i + count] == row[i] { count += 1 }
                out.append(UInt8(bitPattern: Int8(-(count - 1))))
                out.append(row[i])
                i += count
            } else {
                let start = i
                i += 1
                while i < end, i - start < 128 {
                    if i + 1 < end, row[i] == row[i + 1] { break }
                    i += 1
                }
                let count = i - start
                out.append(UInt8(count - 1))
                out.append(contentsOf: row[start..<i])
            }
        }
        return out
    }

    static func unpack(_ source: Data, count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var i = 0
        let bytes = [UInt8](source)
        while out.count < count {
            guard i < bytes.count else { throw PSDError.invalid }
            let n = Int8(bitPattern: bytes[i]); i += 1
            if n >= 0 {
                let length = Int(n) + 1
                guard i + length <= bytes.count, out.count + length <= count else { throw PSDError.invalid }
                out.append(contentsOf: bytes[i..<(i + length)])
                i += length
            } else if n > -128 {
                let length = Int(-n) + 1
                guard i < bytes.count, out.count + length <= count else { throw PSDError.invalid }
                out.append(contentsOf: repeatElement(bytes[i], count: length))
                i += 1
            }
        }
        return out
    }

    static func packPlane(_ plane: [UInt8], width: Int, height: Int) -> Data {
        guard width > 0, height > 0 else { return Data() }
        var counts = Data()
        var payload = Data()
        counts.reserveCapacity(height * 2)
        for y in 0..<height {
            let packed = pack(plane[(y * width)..<((y + 1) * width)])
            let count = UInt16(min(packed.count, Int(UInt16.max)))
            counts.append(UInt8(count >> 8))
            counts.append(UInt8(count & 0xff))
            payload.append(contentsOf: packed)
        }
        var result = Data()
        result.append(contentsOf: [0, 1])
        result.append(counts)
        result.append(payload)
        return result
    }

    static func unpackPlane(_ cursor: PSDCursor, width: Int, height: Int, compression: Int, expected: Int) throws -> [UInt8] {
        let count = width * height
        guard count >= 0 else { throw PSDError.invalid }
        if count == 0 { return [] }
        switch compression {
        case 0:
            return [UInt8](try cursor.bytes(count))
        case 1:
            var counts: [Int] = []
            counts.reserveCapacity(height)
            var total = 0
            for _ in 0..<height {
                let row = Int(try cursor.u16())
                guard row >= 0, total <= Int.max - row else { throw PSDError.invalid }
                counts.append(row)
                total += row
            }
            var packed = Data()
            packed.reserveCapacity(total)
            for row in counts { packed.append(try cursor.bytes(row)) }
            return try unpack(packed, count: count)
        case 2, 3:
            let zip = try cursor.bytes(max(0, expected - 2))
            var plane = try inflate(zip, count: count)
            if compression == 3 { predict(&plane, width: width, height: height) }
            return plane
        default:
            throw PSDError.unsupportedCompression
        }
    }
}

nonisolated func inflate(_ source: Data, count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    func decode(_ input: Data) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: count)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { src -> Int in
                guard let inPtr = src.bindMemory(to: UInt8.self).baseAddress,
                      let outPtr = out.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outPtr, count, inPtr, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == count ? output : nil
    }
    if let plane = decode(source) { return plane }
    var wrapped = Data([0x78, 0x9c])
    wrapped.append(source)
    if let plane = decode(wrapped) { return plane }
    throw PSDError.unsupportedCompression
}

nonisolated func predict(_ plane: inout [UInt8], width: Int, height: Int) {
    guard width > 1 else { return }
    for y in 0..<height {
        let row = y * width
        for x in 1..<width { plane[row + x] = plane[row + x] &+ plane[row + x - 1] }
    }
}

nonisolated enum PSDBlend {
    static func mode(for key: UInt32) -> LayerBlendMode {
        switch key {
        case PSDFourCC.code("mul "): return .multiply
        case PSDFourCC.code("scrn"): return .screen
        case PSDFourCC.code("over"): return .overlay
        case PSDFourCC.code("dark"): return .darken
        case PSDFourCC.code("lite"): return .lighten
        case PSDFourCC.code("diff"): return .difference
        case PSDFourCC.code("div "): return .colorDodge
        case PSDFourCC.code("idiv"): return .colorBurn
        case PSDFourCC.code("hue "): return .hue
        case PSDFourCC.code("sat "): return .saturation
        case PSDFourCC.code("colr"): return .color
        case PSDFourCC.code("lum "): return .luminosity
        default: return .normal
        }
    }
    static func key(for mode: LayerBlendMode) -> UInt32 {
        switch mode {
        case .normal: return PSDFourCC.code("norm")
        case .multiply: return PSDFourCC.code("mul ")
        case .screen: return PSDFourCC.code("scrn")
        case .overlay: return PSDFourCC.code("over")
        case .darken: return PSDFourCC.code("dark")
        case .lighten: return PSDFourCC.code("lite")
        case .difference: return PSDFourCC.code("diff")
        case .colorDodge: return PSDFourCC.code("div ")
        case .colorBurn: return PSDFourCC.code("idiv")
        case .hue: return PSDFourCC.code("hue ")
        case .saturation: return PSDFourCC.code("sat ")
        case .color: return PSDFourCC.code("colr")
        case .luminosity: return PSDFourCC.code("lum ")
        }
    }
}
