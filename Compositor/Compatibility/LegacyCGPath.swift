import CoreGraphics

/// Boolean path operations were added to CGPath in macOS 13. On Monterey, selections use a
/// pixel mask fallback so the editing model keeps the same union/intersection/subtraction semantics.
nonisolated enum LegacyCGPath {
    static func intersection(_ lhs: CGPath, _ rhs: CGPath, in bounds: CGRect) -> CGPath {
        if #available(macOS 13.0, *) {
            return lhs.intersection(rhs, using: .winding)
        }
        return raster(lhs, rhs, bounds: bounds, operation: .intersection)
    }

    static func union(_ lhs: CGPath, _ rhs: CGPath, in bounds: CGRect) -> CGPath {
        if #available(macOS 13.0, *) {
            return lhs.union(rhs, using: .winding)
        }
        return raster(lhs, rhs, bounds: bounds, operation: .union)
    }

    static func subtracting(_ lhs: CGPath, _ rhs: CGPath, in bounds: CGRect) -> CGPath {
        if #available(macOS 13.0, *) {
            return lhs.subtracting(rhs, using: .winding)
        }
        return raster(lhs, rhs, bounds: bounds, operation: .subtract)
    }

    private enum Operation {
        case intersection, union, subtract
    }

    private static func raster(_ lhs: CGPath, _ rhs: CGPath, bounds: CGRect, operation: Operation) -> CGPath {
        let width = max(1, Int(ceil(bounds.width)))
        let height = max(1, Int(ceil(bounds.height)))
        var first = mask(for: lhs, bounds: bounds, width: width, height: height)
        let second = mask(for: rhs, bounds: bounds, width: width, height: height)
        for index in first.indices {
            switch operation {
            case .intersection:
                first[index] = min(first[index], second[index])
            case .union:
                first[index] = max(first[index], second[index])
            case .subtract:
                if second[index] > 0 { first[index] = 0 }
            }
        }
        return path(from: first, bounds: bounds, width: width, height: height)
    }

    private static func mask(for path: CGPath, bounds: CGRect, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.addPath(path)
            context.fillPath(using: .winding)
        }
        return pixels
    }

    private static func path(from pixels: [UInt8], bounds: CGRect, width: Int, height: Int) -> CGPath {
        let result = CGMutablePath()
        for row in 0..<height {
            var column = 0
            while column < width {
                while column < width && pixels[row * width + column] == 0 { column += 1 }
                let start = column
                while column < width && pixels[row * width + column] > 0 { column += 1 }
                if column > start {
                    result.addRect(CGRect(x: bounds.minX + CGFloat(start), y: bounds.minY + CGFloat(row),
                                          width: CGFloat(column - start), height: 1))
                }
            }
        }
        return result
    }
}
