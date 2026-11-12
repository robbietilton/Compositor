import AppKit
import Testing
@testable import Compositor

/// A stroke reaches the same distance in every direction: a circle's stroke is a ring of even width, inside or
/// outside, on the GPU and in the CPU fallback alike.
@MainActor struct StrokeEffectTests {
    /// A 200 × 200 image with a black disc of radius 60 in the middle.
    private func disc() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 40, width: 120, height: 120))
        return try #require(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> (bytes: [UInt8], width: Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width)
    }

    /// How far from `center` along `angle` the last pixel matching `test` lies, walking out from the middle.
    private func reach(_ image: CGImage, center: CGPoint, angle: Double, matching test: ([UInt8]) -> Bool) throws -> Double {
        let (bytes, width) = try pixels(image)
        var last = 0.0
        for step in 0...400 {
            let distance = Double(step) * 0.25
            let x = Int(center.x + cos(angle) * distance), y = Int(center.y + sin(angle) * distance)
            guard x >= 0, y >= 0, x < width, y < image.height else { break }
            let at = (y * width + x) * 4
            if test(Array(bytes[at..<at + 4])) { last = distance }
        }
        return last
    }

    /// The ring's outer and inner radii at the sides and on a diagonal.
    private func radii(_ effects: LayerEffects) throws -> (outer: [Double], inner: [Double]) {
        let (image, inset) = try LayerEffectsRenderer.render(try disc(), mask: nil, effects: effects)
        let center = CGPoint(x: 100 + inset, y: 100 + inset)
        let angles = [0, Double.pi / 4, Double.pi / 2, 3 * Double.pi / 4]
        let outer = try angles.map { try reach(image, center: center, angle: $0) { $0[3] > 127 } }
        // The stroke is red over the black disc: the inner edge is where red starts, walking out.
        let inner = try angles.map { angle in
            let (bytes, width) = try pixels(image)
            for step in 0...400 {
                let distance = Double(step) * 0.25
                let x = Int(center.x + cos(angle) * distance), y = Int(center.y + sin(angle) * distance)
                let at = (y * width + x) * 4
                if bytes[at] > 127 { return distance }
            }
            return 0
        }
        return (outer, inner)
    }

    @Test(arguments: [false, true])
    func aCirclesStrokeIsEvenAllTheWayRound(inside: Bool) throws {
        let effects = LayerEffects(stroke: StrokeEffect(size: 12, red: 1, green: 0, blue: 0, opacity: 1, inside: inside))
        let (outer, inner) = try radii(effects)
        // Outside: from 60 out to 72. Inside: from 48 out to 60. A square reach made the diagonals about 5 px off.
        for value in outer { #expect(abs(value - (inside ? 60 : 72)) < 1.5, "outer edges \(outer)") }
        for value in inner { #expect(abs(value - (inside ? 48 : 60)) < 1.5, "inner edges \(inner)") }
    }

    /// The CPU fallback's ring, directly: the same widths as the GPU's.
    @Test(arguments: [false, true])
    func theCPUFallbackMatches(inside: Bool) throws {
        let stroke = StrokeEffect(size: 12, red: 1, green: 0, blue: 0, opacity: 1, inside: inside)
        let ring = try LayerEffectsRenderer.ringCoverage(try disc(), in: CGSize(width: 200, height: 200), stroke: stroke)
        let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 200,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(ring, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for angle in [0, Double.pi / 4, Double.pi / 2, 3 * Double.pi / 4] {
            var first = -1.0, last = -1.0
            for step in 0...360 {
                let distance = Double(step) * 0.25
                let x = Int(100 + cos(angle) * distance), y = Int(100 + sin(angle) * distance)
                if bytes[y * 200 + x] > 127 { if first < 0 { first = distance }; last = distance }
            }
            #expect(abs(first - (inside ? 48 : 60)) < 1.5 && abs(last - (inside ? 60 : 72)) < 1.5,
                    "at \(angle): the ring runs \(first)–\(last)")
        }
    }

    /// An inside stroke keeps a square's corners square; an outside one rounds them, as Photoshop's does.
    @Test func aSquaresCorners() throws {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        let square = try #require(context.makeImage())
        for inside in [false, true] {
            let effects = LayerEffects(stroke: StrokeEffect(size: 10, red: 1, green: 0, blue: 0, opacity: 1, inside: inside))
            let (image, inset) = try LayerEffectsRenderer.render(square, mask: nil, effects: effects)
            let (bytes, width) = try pixels(image)
            func red(_ x: Int, _ y: Int) -> Bool {
                let at = ((y + Int(inset)) * width + x + Int(inset)) * 4
                return bytes[at + 3] > 127 && bytes[at] > 127
            }
            if inside {
                #expect(red(30, 30) && red(69, 69), "an inside stroke reaches into the square's corners")
            } else {
                #expect(red(25, 50) && !red(22, 22), "an outside stroke's corner is round, not square")
            }
        }
    }
}
