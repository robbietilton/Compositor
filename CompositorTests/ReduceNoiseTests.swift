import AppKit
import Testing
@testable import Compositor

/// Filter › Reduce Noise: Camera Raw's noise reduction on its own.
struct ReduceNoiseTests {
    static let size = 120

    /// Mid gray with every pixel's brightness and color thrown a little off at random, as a high-ISO photo's are; with
    /// `edge`, dark on the left half and light on the right.
    private func noisy(edge: Bool = false) throws -> CGImage {
        let context = try BrushRaster.context(width: Self.size, height: Self.size, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var random = SystemRandomNumberGenerator()
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let p = bytes + y * context.bytesPerRow + x * 4
                let base = edge ? (x < Self.size / 2 ? 70 : 190) : 128
                let shift = Int.random(in: -30...30, using: &random)
                for channel in 0..<3 { p[channel] = UInt8(base + shift + Int.random(in: -20...20, using: &random)) }
                p[3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// How far each pixel's channels stray from the image's mean on average: its noise.
    private func spread(_ image: CGImage) throws -> Double {
        let context = try BrushRaster.copy(image)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var values: [Double] = []
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                for channel in 0..<3 { values.append(Double(bytes[y * context.bytesPerRow + x * 4 + channel])) }
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + abs($1 - mean) } / Double(values.count)
    }

    private func reduced(edge: Bool = false, _ change: (inout FilterSettings) -> Void = { _ in }) throws -> CGImage {
        var settings = FilterSettings()
        change(&settings)
        return try PixelFilter.run(FilterJob(kind: .reduceNoise, image: try noisy(edge: edge), settings: settings, scale: 1, selection: nil,
                                             mapping: .identity))
    }

    @Test func itSmoothsTheNoise() throws {
        let before = try spread(noisy()), after = try spread(reduced())
        #expect(after < before * 0.7, "noise \(after) after, against \(before) before")
    }

    @Test func moreStrengthSmoothsMore() throws {
        let light = try spread(reduced { $0.reduceNoiseLuminance = 20 }), strong = try spread(reduced { $0.reduceNoiseLuminance = 100 })
        #expect(strong < light, "\(strong) at full strength, against \(light) at 20")
    }

    /// Non-local means, not a blur: the grain goes, but the edge between dark and light stays a step, not a ramp.
    @Test func itKeepsEdges() throws {
        let context = try BrushRaster.copy(try reduced(edge: true) { $0.reduceNoiseLuminance = 100 })
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        func column(_ x: Int) -> Double {
            Double((0..<Self.size).reduce(0) { $0 + Int(bytes[$1 * context.bytesPerRow + x * 4 + 1]) }) / Double(Self.size)
        }
        let middle = Self.size / 2
        #expect(column(middle) - column(middle - 1) > 90, "the step across the edge: \(column(middle - 1)) to \(column(middle))")
    }
}
