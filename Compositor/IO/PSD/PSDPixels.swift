import CoreGraphics
import Foundation

nonisolated enum PSDPixels {
    struct RGBA {
        var r: [UInt8]
        var g: [UInt8]
        var b: [UInt8]
        var a: [UInt8]
        var width: Int
        var height: Int
        var count: Int { width * height }
    }

    static func rgba(from image: CGImage) throws -> RGBA {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else {
            return RGBA(r: [], g: [], b: [], a: [], width: width, height: height)
        }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let count = width * height
        var r = [UInt8](repeating: 0, count: count)
        var g = [UInt8](repeating: 0, count: count)
        var b = [UInt8](repeating: 0, count: count)
        var a = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let pr = Int(pixels[i * 4]), pg = Int(pixels[i * 4 + 1]), pb = Int(pixels[i * 4 + 2]), pa = Int(pixels[i * 4 + 3])
            a[i] = UInt8(pa)
            if pa == 0 { continue }
            if pa == 255 {
                r[i] = UInt8(pr); g[i] = UInt8(pg); b[i] = UInt8(pb)
            } else {
                r[i] = UInt8(min(255, (pr * 255 + pa / 2) / pa))
                g[i] = UInt8(min(255, (pg * 255 + pa / 2) / pa))
                b[i] = UInt8(min(255, (pb * 255 + pa / 2) / pa))
            }
        }
        return RGBA(r: r, g: g, b: b, a: a, width: width, height: height)
    }

    static func image(_ planes: RGBA) throws -> CGImage {
        let width = planes.width, height = planes.height, count = planes.count
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            let a = Int(planes.a[i])
            pixels[i * 4 + 3] = UInt8(a)
            if a == 0 {
                pixels[i * 4] = 0; pixels[i * 4 + 1] = 0; pixels[i * 4 + 2] = 0
            } else if a == 255 {
                pixels[i * 4] = planes.r[i]; pixels[i * 4 + 1] = planes.g[i]; pixels[i * 4 + 2] = planes.b[i]
            } else {
                pixels[i * 4] = UInt8((Int(planes.r[i]) * a + 127) / 255)
                pixels[i * 4 + 1] = UInt8((Int(planes.g[i]) * a + 127) / 255)
                pixels[i * 4 + 2] = UInt8((Int(planes.b[i]) * a + 127) / 255)
            }
        }
        guard let image = context.makeImage() else { throw PSDError.encode }
        return image
    }

    static func imported(_ planes: RGBA, name: String) throws -> ImportedImage {
        let image = try Self.image(planes)
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: name)
    }

    static func mask(_ plane: [UInt8], width: Int, height: Int) throws -> ImportedImage {
        guard width > 0, height > 0, plane.count >= width * height else { throw PSDError.invalid }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width { pixels[y * context.bytesPerRow + x] = plane[y * width + x] }
        }
        guard let image = context.makeImage() else { throw PSDError.encode }
        return try LayerMask.asset(from: image)
    }

    static func maskPlane(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        LayerMask.drawSmooth(image, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var plane = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { plane[y * width + x] = pixels[y * context.bytesPerRow + x] }
        }
        return plane
    }
}
