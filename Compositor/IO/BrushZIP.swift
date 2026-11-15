import Foundation
import zlib

nonisolated enum BrushImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): "Couldn’t import brushes: " + detail }
    }
}

/// ZIP entries stay in memory: untrusted names are never extracted to filesystem paths.
nonisolated struct BrushZIP {
    struct Budget {
        var bytes = 0
        var entries = 0
    }
    struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let size: Int
        let compressed: Range<Int>
    }
    let entries: [Entry]
    private let bytes: Data

    init(_ data: Data, budget: inout Budget) throws {
        guard data.count >= 22, data.count <= 512 * 1024 * 1024 else { throw BrushImportError.invalid("Invalid archive size.") }
        bytes = data
        var end: Int?
        for position in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try Self.number(data, position, 4) == 0x06054b50,
               position + 22 + (try Self.number(data, position + 20, 2)) == data.count { end = position; break }
        }
        guard let end else { throw BrushImportError.invalid("ZIP directory is missing.") }
        let count = try Self.number(data, end + 10, 2)
        let directorySize = try Self.number(data, end + 12, 4)
        let directory = try Self.number(data, end + 16, 4)
        guard try Self.number(data, end + 4, 2) == 0, try Self.number(data, end + 6, 2) == 0,
              try Self.number(data, end + 8, 2) == count, count < 65535,
              directory + directorySize == end, directory <= end else {
            throw BrushImportError.invalid("Split or ZIP64 archives aren’t supported.")
        }
        budget.entries += count
        guard budget.entries <= 20000 else { throw BrushImportError.invalid("Too many archive entries.") }
        var offset = directory
        var parsed: [Entry] = []
        var names = Set<String>()
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try Self.number(data, offset, 4) == 0x02014b50 else { throw BrushImportError.invalid("Invalid ZIP directory.") }
            let flags = try Self.number(data, offset + 8, 2)
            let method = try Self.number(data, offset + 10, 2)
            let checksum = try Self.number(data, offset + 16, 4)
            let compressedSize = try Self.number(data, offset + 20, 4)
            let size = try Self.number(data, offset + 24, 4)
            let nameSize = try Self.number(data, offset + 28, 2)
            let extraSize = try Self.number(data, offset + 30, 2)
            let commentSize = try Self.number(data, offset + 32, 2)
            let mode = try Self.number(data, offset + 38, 4) >> 16
            let local = try Self.number(data, offset + 42, 4)
            let next = offset + 46 + nameSize + extraSize + commentSize
            guard next <= end, try Self.number(data, offset + 34, 2) == 0,
                  flags & 0x41 == 0, method == 0 || method == 8, size <= 64 * 1024 * 1024,
                  mode & 0o170000 != 0o120000,
                  mode & 0o170000 == 0 || mode & 0o170000 == 0o100000 || mode & 0o170000 == 0o040000,
                  let name = String(data: data.subdata(in: offset + 46..<offset + 46 + nameSize), encoding: .utf8),
                  Self.safePath(name) else { throw BrushImportError.invalid("Unsafe or unsupported ZIP entry.") }
            let key = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else { throw BrushImportError.invalid("Duplicate archive path: " + name) }
            budget.bytes += size
            guard budget.bytes <= 512 * 1024 * 1024 else { throw BrushImportError.invalid("Expanded archives exceed 512 MiB.") }
            guard local < directory, try Self.number(data, local, 4) == 0x04034b50,
                  try Self.number(data, local + 6, 2) == flags, try Self.number(data, local + 8, 2) == method else {
                throw BrushImportError.invalid("ZIP entry headers disagree.")
            }
            let localNameSize = try Self.number(data, local + 26, 2)
            let localExtra = try Self.number(data, local + 28, 2)
            let start = local + 30 + localNameSize + localExtra
            guard start <= directory, start + compressedSize <= directory,
                  localNameSize == nameSize,
                  data.subdata(in: local + 30..<local + 30 + localNameSize) == data.subdata(in: offset + 46..<offset + 46 + nameSize) else {
                throw BrushImportError.invalid("Invalid ZIP entry bounds.")
            }
            if flags & 8 == 0 {
                guard try Self.number(data, local + 14, 4) == checksum,
                      try Self.number(data, local + 18, 4) == compressedSize, try Self.number(data, local + 22, 4) == size else {
                    throw BrushImportError.invalid("ZIP entry sizes disagree.")
                }
            }
            ranges.append(local..<start + compressedSize)
            if !name.hasSuffix("/") {
                parsed.append(Entry(name: name, method: method, crc: UInt32(checksum), size: size,
                                    compressed: start..<start + compressedSize))
            } else if size != 0 { throw BrushImportError.invalid("Invalid ZIP directory entry.") }
            offset = next
        }
        guard offset == end else { throw BrushImportError.invalid("ZIP directory size disagrees.") }
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in ordered.indices.dropFirst() where ordered[index - 1].upperBound > ordered[index].lowerBound {
            throw BrushImportError.invalid("Overlapping ZIP entries.")
        }
        entries = parsed
    }

    func read(_ entry: Entry) throws -> Data {
        let compressed = bytes.subdata(in: entry.compressed)
        let output: Data
        if entry.method == 0 {
            guard compressed.count == entry.size else { throw BrushImportError.invalid("Invalid stored ZIP entry.") }
            output = compressed
        } else {
            var result = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw BrushImportError.invalid("Couldn’t initialize ZIP decoding.")
            }
            defer { inflateEnd(&stream) }
            let status: Int32 = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == compressed.count else {
                throw BrushImportError.invalid("Invalid or oversized compressed entry: " + entry.name)
            }
            result.count = entry.size
            output = result
        }
        let checksum = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard UInt32(checksum) == entry.crc else { throw BrushImportError.invalid("ZIP checksum mismatch: " + entry.name) }
        return output
    }

    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        let parts = path.hasSuffix("/") ? String(path.dropLast()).components(separatedBy: "/") : path.components(separatedBy: "/")
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) throws -> Int {
        guard offset >= 0, offset <= data.count, count <= data.count - offset else {
            throw BrushImportError.invalid("Truncated ZIP header.")
        }
        return (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
}
