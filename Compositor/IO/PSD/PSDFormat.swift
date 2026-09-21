import Foundation
import CoreGraphics

/// Errors and byte-level helpers shared by the PSD reader, importer and layered writer.
/// Format facts follow the Adobe specification as cross-checked against psd-tools 1.19.0
/// and a byte-level probe of a real Photoshop file (see docs and psd-spec-notes.md).
nonisolated enum PSDImportError: LocalizedError {
    case unreadable, damaged(String), psb, depth(Int), colorMode(Int)
    case zipChannels, canvasTooLarge(width: Int, height: Int), nothingImported
    var errorDescription: String? {
        switch self {
        case .unreadable: return "The PSD could not be read. It may be damaged or unavailable."
        case .damaged(let detail): return "The PSD appears damaged: \(detail)."
        case .psb: return "This is a PSB (large document format) file. Save it as a standard PSD to import it."
        case .depth(let depth): return "This PSD uses \(depth)-bit channels. Only 8-bit RGB PSD files are supported."
        case .colorMode(let mode):
            return "This PSD uses color mode \(mode) instead of RGB. Only 8-bit RGB PSD files are supported."
        case .zipChannels: return "This PSD stores layer pixels with ZIP compression, which is not supported."
        case .canvasTooLarge(let width, let height):
            let megapixels = (Double(width) * Double(height) / 1_000_000).rounded(.toNearestOrEven)
            return "The PSD canvas is \(width) × \(height) pixels (\(Int(megapixels)) megapixels), beyond the "
                + "100-megapixel document budget, and the file has no artboards to split it by. "
                + "Split it into artboards or save it smaller."
        case .nothingImported: return "The PSD contains no layers that can be imported."
        }
    }
}

nonisolated enum PSDFormat {
    static let signature = Array("8BPS".utf8)
    /// The signature blend modes and tagged blocks carry inside layer records (not the file header's).
    static let blockSignature = Array("8BIM".utf8)

    /// The PSD blend-mode keys this app maps to its nine layer blend modes, spelled exactly
    /// as Photoshop writes them (trailing spaces included). `dkCl` (Darker Color) has no
    /// equivalent here and downgrades to Darken; callers surface that in the import summary.
    static func blendMode(forPSDKey key: String) -> (mode: LayerBlendMode, downgraded: Bool) {
        switch key {
        case "mul ": (.multiply, false)
        case "scrn": (.screen, false)
        case "over": (.overlay, false)
        case "dark", "dkCl": (.darken, key == "dkCl")
        case "lite": (.lighten, false)
        case "diff": (.difference, false)
        case "div ": (.colorDodge, false)
        case "idiv": (.colorBurn, false)
        case "soft": (.softLight, false)
        case "norm": (.normal, false)
        default: (.normal, true)
        }
    }
    static func psdKey(for mode: LayerBlendMode) -> String {
        switch mode {
        case .normal: "norm"
        case .multiply: "mul "
        case .screen: "scrn"
        case .overlay: "over"
        case .darken: "dark"
        case .lighten: "lite"
        case .difference: "diff"
        case .colorDodge: "div "
        case .colorBurn: "idiv"
        case .softLight: "soft"
        case .hue, .saturation, .color, .luminosity: "norm" // No PSD counterpart in this mapping.
        }
    }

    // MARK: PackBits

    /// Decodes one PackBits row of `width` bytes into `output` at `offset`. 0..127 = n+1
    /// literals; 129..255 = 257-n repeats of the next byte; 128 = no-op. Literal and repeat
    /// runs copy through memcpy/memset so multi-hundred-megabyte files stay quick.
    static func unpackRow(_ input: ArraySlice<UInt8>, into output: inout [UInt8], at offset: Int, width: Int) throws {
        var written = 0
        guard output.count >= offset + width else { throw PSDImportError.damaged("a scanline buffer is too small") }
        try input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { throw PSDImportError.damaged("an empty compressed row") }
            try output.withUnsafeMutableBufferPointer { destination in
                var cursor = base
                let rowEnd = base + input.count
                while written < width {
                    guard cursor < rowEnd else { throw PSDImportError.damaged("a compressed row ended early") }
                    let header = cursor.pointee
                    cursor += 1
                    if header <= 127 {
                        let count = Int(header) + 1
                        guard cursor + count <= rowEnd, written + count <= width else {
                            throw PSDImportError.damaged("a compressed row overran its scanline")
                        }
                        memcpy(destination.baseAddress! + offset + written, cursor, count)
                        cursor += count
                        written += count
                    } else if header >= 129 {
                        let count = 257 - Int(header)
                        guard cursor < rowEnd, written + count <= width else {
                            throw PSDImportError.damaged("a compressed row overran its scanline")
                        }
                        memset(destination.baseAddress! + offset + written, Int32(cursor.pointee), count)
                        cursor += 1
                        written += count
                    } // 128: no-op
                }
                guard cursor == rowEnd else { throw PSDImportError.damaged("a compressed row had trailing bytes") }
            }
        }
    }

    /// Standard PackBits encoding of one scanline (same output shape Photoshop accepts).
    static func packBits(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count + input.count / 64)
        var index = input.startIndex
        let end = input.endIndex
        while index < end {
            var run = 1
            while index + run < end && input[index + run] == input[index] && run < 128 { run += 1 }
            if run >= 3 {
                out.append(UInt8(257 - run))
                out.append(input[index])
                index += run
            } else {
                let literalStart = index
                var literalCount = 0
                while index < end {
                    var next = 1
                    while index + next < end && input[index + next] == input[index] && next < 128 { next += 1 }
                    if next >= 3 { break } // a worthwhile run starts here; keep it for a repeat packet
                    // A literal packet carries at most 128 bytes; `next` can be 2, so cap before adding,
                    // or the header degenerates into the no-op control byte 128 and shifts the whole row.
                    if literalCount + next > 128 { break }
                    index += next
                    literalCount += next
                }
                out.append(UInt8(literalCount - 1))
                out.append(contentsOf: input[literalStart..<literalStart + literalCount])
            }
        }
        return out
    }

    /// The RLE channel body (row table + PackBits rows) for a plane of `width` × `height` bytes.
    static func rleChannel(_ plane: ArraySlice<UInt8>, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 2 + 2 * height)
        out[0] = 0; out[1] = 1 // compression = 1, RLE
        for y in 0..<height {
            let row = packBits(plane[plane.startIndex + y * width ..< plane.startIndex + (y + 1) * width])
            out[2 + 2 * y] = UInt8(truncatingIfNeeded: row.count >> 8)
            out[3 + 2 * y] = UInt8(truncatingIfNeeded: row.count)
            out.append(contentsOf: row)
        }
        return out
    }
}

/// Growable big-endian byte buffer for assembling PSD sections.
nonisolated struct PSDWriter {
    private(set) var bytes = [UInt8]()
    var count: Int { bytes.count }

    mutating func append(_ value: UInt8) { bytes.append(value) }
    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    mutating func append(_ data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8)); bytes.append(UInt8(truncatingIfNeeded: value))
    }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24)); bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8)); bytes.append(UInt8(truncatingIfNeeded: value))
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32)); u32(UInt32(truncatingIfNeeded: value))
    }
    mutating func ascii(_ text: String) { bytes.append(contentsOf: Array(text.utf8.prefix(255))) }
    mutating func pad(to multiple: Int) {
        guard multiple > 1 else { return }
        while bytes.count % multiple != 0 { bytes.append(0) }
    }
    mutating func patchU32(at offset: Int, _ value: UInt32) {
        precondition(offset + 4 <= bytes.count)
        var position = offset
        for shift in [24, 16, 8, 0] {
            bytes[position] = UInt8((value >> UInt32(shift)) & 0xFF)
            position += 1
        }
    }
    var slice: ArraySlice<UInt8> { bytes[...] }
}
