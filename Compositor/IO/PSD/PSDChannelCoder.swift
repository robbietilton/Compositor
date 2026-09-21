import CoreGraphics
import Foundation

/// Unpacks Photoshop layer channels from Adobe’s 2019 Photoshop File Formats
/// Specification (Image Data, compression 0 raw and 1 PackBits).
nonisolated enum PSDChannelCoder {
    static func decode(compression: Int, width: Int, height: Int, data: Data) throws -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        let expected = width * height
        switch compression {
        case 0:
            guard data.count >= expected else { throw PSDError.truncated }
            return Array(data.prefix(expected))
        case 1:
            return try unpackRLE(width: width, height: height, data: data)
        default:
            throw PSDError.unsupportedCompression
        }
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

    private static func unpackRLE(width: Int, height: Int, data: Data) throws -> [UInt8] {
        var offset = 0
        func next() throws -> UInt8 {
            guard offset < data.count else { throw PSDError.truncated }
            defer { offset += 1 }
            return data[offset]
        }
        var counts = [Int](repeating: 0, count: height)
        for row in 0..<height {
            let hi = try next(), lo = try next()
            counts[row] = Int(hi) << 8 | Int(lo)
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
}
