import Foundation

/// Forward-only buffered reader over a PSD on disk. The file is read in bounded chunks
/// (never mapped or loaded whole), so a multi-gigabyte document costs a fixed buffer
/// plus whatever the caller materializes per layer.
nonisolated struct PSDFileReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private var position: UInt64 = 0
    private var buffer = [UInt8]()   // Bytes [bufferStart, bufferStart+buffer.count) from the file.
    private var bufferStart: UInt64 = 0
    private var consumed = 0         // Prefix of `buffer` already handed out.
    private static let capacity = 1 << 20

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? UInt64, size > 0 else { throw PSDImportError.unreadable }
        fileSize = size
    }

    var offset: UInt64 { position }
    var remaining: UInt64 { fileSize - position }

    private mutating func fill(minimum: Int) throws {
        if buffer.count - consumed >= minimum { return }
        if consumed > 0 {
            buffer.removeFirst(consumed)
            bufferStart += UInt64(consumed)
            consumed = 0
        }
        let wanted = max(Self.capacity, minimum - buffer.count)
        let chunk = try handle.read(upToCount: wanted) ?? Data()
        buffer.append(contentsOf: chunk)
        // Shortfalls (end of file, or a short read) are judged by `read`, which knows the exact count.
    }

    /// Reads exactly `count` bytes.
    mutating func read(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        guard position + UInt64(count) <= fileSize else { throw PSDImportError.damaged("read past end of file") }
        if count >= Self.capacity {
            // Large reads bypass the buffer entirely so channel data never gets copied twice.
            buffer.removeAll(keepingCapacity: false)
            bufferStart = position
            consumed = 0
            try handle.seek(toOffset: position)
            var out = [UInt8]()
            out.reserveCapacity(count)
            while out.count < count {
                guard let chunk = try handle.read(upToCount: count - out.count), !chunk.isEmpty else {
                    throw PSDImportError.damaged("the file ended unexpectedly")
                }
                out.append(contentsOf: chunk)
            }
            position += UInt64(count)
            return out
        }
        try fill(minimum: count)
        guard buffer.count - consumed >= count else { throw PSDImportError.damaged("the file ended unexpectedly") }
        let result = Array(buffer[consumed..<consumed + count])
        consumed += count
        position += UInt64(count)
        return result
    }

    /// Advances past `count` bytes without materializing them.
    mutating func skip(_ count: UInt64) throws {
        guard position + count <= fileSize else { throw PSDImportError.damaged("read past end of file") }
        let buffered = UInt64(buffer.count - consumed)
        if count <= buffered {
            consumed += Int(count)
            position += count
        } else {
            position += count
            buffer.removeAll(keepingCapacity: false)
            bufferStart = position
            consumed = 0
            try handle.seek(toOffset: position)
        }
    }

    mutating func readU8() throws -> UInt8 { try read(1)[0] }

    /// Moves the cursor forward to an absolute offset (parsing pads and skipped blocks).
    mutating func seek(to target: UInt64) throws {
        guard target >= position else { throw PSDImportError.damaged("the file layout went backwards") }
        if target > position { try skip(target - position) }
    }

    mutating func readU16() throws -> UInt16 {
        let b = try read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    mutating func readI16() throws -> Int16 { Int16(bitPattern: try readU16()) }
    mutating func readU32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    mutating func readI32() throws -> Int32 { Int32(bitPattern: try readU32()) }
    mutating func readU64() throws -> UInt64 {
        let high = UInt64(try readU32()), low = UInt64(try readU32())
        return high << 32 | low
    }
    /// A fixed 16.16 big-endian value, as the resolution resource stores DPI.
    mutating func readFixed32() throws -> Double { Double(try readI32()) / 65_536 }
    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readU64())
    }
    /// Reads a 4-byte ASCII tag, or nil at end of data (used to stop tagged-block walks).
    mutating func readTag() throws -> String? {
        guard remaining >= 4 else { return nil }
        return String(bytes: try read(4), encoding: .ascii) ?? ""
    }
}
