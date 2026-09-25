import CoreGraphics
import Foundation

nonisolated struct PSDCrop: Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Unpacks Photoshop layer channels from Adobe’s 2019 Photoshop File Formats
/// Specification (Image Data, compression 0 raw and 1 PackBits).
nonisolated enum PSDChannelCoder {
    static func decode(compression: Int, width: Int, height: Int, data: Data, largeDocument: Bool = false,
                       crop: PSDCrop? = nil) throws -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        guard let crop else {
            return try decodeFull(compression: compression, width: width, height: height, data: data, largeDocument: largeDocument)
        }
        guard crop.x >= 0, crop.y >= 0, crop.width >= 0, crop.height >= 0,
              crop.x + crop.width <= width, crop.y + crop.height <= height else { throw PSDError.truncated }
        guard crop.width > 0, crop.height > 0 else { return [] }
        switch compression {
        case 0:
            return try cropRaw(width: width, height: height, data: data, crop: crop)
        case 1:
            return try unpackRLE(width: width, height: height, data: data, largeDocument: largeDocument, crop: crop)
        default:
            throw PSDError.unsupportedCompression
        }
    }

    private static func decodeFull(compression: Int, width: Int, height: Int, data: Data, largeDocument: Bool) throws -> [UInt8] {
        let expected = width * height
        switch compression {
        case 0:
            guard data.count >= expected else { throw PSDError.truncated }
            return Array(data.prefix(expected))
        case 1:
            return try unpackRLE(width: width, height: height, data: data, largeDocument: largeDocument)
        default:
            throw PSDError.unsupportedCompression
        }
    }

    private static func cropRaw(width: Int, height: Int, data: Data, crop: PSDCrop) throws -> [UInt8] {
        let expected = width * height
        guard data.count >= expected else { throw PSDError.truncated }
        var plane = [UInt8](repeating: 0, count: crop.width * crop.height)
        for row in 0..<crop.height {
            let sourceStart = (crop.y + row) * width + crop.x
            let targetStart = row * crop.width
            plane.replaceSubrange(targetStart..<(targetStart + crop.width), with: data[sourceStart..<(sourceStart + crop.width)])
        }
        return plane
    }

    static func rgbaImage(width: Int, height: Int, red: [UInt8], green: [UInt8], blue: [UInt8], alpha: [UInt8]) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let count = width * height
        for i in 0..<count {
            let a = alpha[i]
            pixels[i * 4] = UInt8((UInt16(red[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 1] = UInt8((UInt16(green[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 2] = UInt8((UInt16(blue[i]) * UInt16(a) + 127) / 255)
            pixels[i * 4 + 3] = a
        }
        return try image(width: width, height: height, rgba: pixels)
    }

    static func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let bytesPerRow = width * 4
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PSDError.truncated }
        return image
    }

    static func maskImage(width: Int, height: Int, gray: [UInt8]) throws -> CGImage {
        let data = Data(gray)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PSDError.truncated }
        return image
    }

    private static func unpackRLE(width: Int, height: Int, data: Data, largeDocument: Bool) throws -> [UInt8] {
        var offset = 0
        func next() throws -> UInt8 {
            guard offset < data.count else { throw PSDError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        var counts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            if largeDocument {
                let a = try next(), b = try next(), c = try next(), d = try next()
                counts[row] = Int(UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
            } else {
                let hi = try next(), lo = try next()
                counts[row] = Int(hi) << 8 | Int(lo)
            }
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let end = offset + counts[row]
            guard end <= data.count else { throw PSDError.truncated }
            var written = 0
            while written < width {
                guard offset < end else { throw PSDError.truncated }
                let n = Int8(bitPattern: data[offset])
                offset += 1
                if n >= 0 {
                    let count = Int(n) + 1
                    guard written + count <= width, offset + count <= end else { throw PSDError.truncated }
                    for i in 0..<count { plane[row * width + written + i] = data[offset + i] }
                    offset += count
                    written += count
                } else if n != -128 {
                    let count = 1 - Int(n)
                    guard written + count <= width, offset < end else { throw PSDError.truncated }
                    let value = data[offset]
                    offset += 1
                    for i in 0..<count { plane[row * width + written + i] = value }
                    written += count
                }
            }
            offset = end
        }
        return plane
    }

    private static func unpackRLE(width: Int, height: Int, data: Data, largeDocument: Bool, crop: PSDCrop) throws -> [UInt8] {
        var offset = 0
        func next() throws -> UInt8 {
            guard offset < data.count else { throw PSDError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        var counts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            if largeDocument {
                let a = try next(), b = try next(), c = try next(), d = try next()
                counts[row] = Int(UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d))
            } else {
                let hi = try next(), lo = try next()
                counts[row] = Int(hi) << 8 | Int(lo)
            }
        }
        var plane = [UInt8](repeating: 0, count: crop.width * crop.height)
        var rowBuffer = [UInt8](repeating: 0, count: width)
        for row in 0..<height {
            let end = offset + counts[row]
            guard end <= data.count else { throw PSDError.truncated }
            guard row >= crop.y, row < crop.y + crop.height else {
                offset = end
                continue
            }
            var written = 0
            while written < width {
                guard offset < end else { throw PSDError.truncated }
                let n = Int8(bitPattern: data[offset])
                offset += 1
                if n >= 0 {
                    let count = Int(n) + 1
                    guard written + count <= width, offset + count <= end else { throw PSDError.truncated }
                    for index in 0..<count { rowBuffer[written + index] = data[offset + index] }
                    offset += count
                    written += count
                } else if n != -128 {
                    let count = 1 - Int(n)
                    guard written + count <= width, offset < end else { throw PSDError.truncated }
                    let value = data[offset]
                    offset += 1
                    for index in 0..<count { rowBuffer[written + index] = value }
                    written += count
                }
            }
            let targetStart = (row - crop.y) * crop.width
            plane.replaceSubrange(targetStart..<(targetStart + crop.width), with: rowBuffer[crop.x..<(crop.x + crop.width)])
            offset = end
        }
        return plane
    }
}
