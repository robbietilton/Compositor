import AppKit
import Testing
@testable import Compositor

/// The Camera Raw kernels run on every core and read opaque pixels from a table, but must give exactly the pixels
/// they gave before: these hashes were recorded from the single-threaded kernels.
struct CameraRawSpeedTests {
    /// A 97 × 61 picture (odd sizes, so no row or chunk divides evenly) with a band of partial alpha and a clear corner.
    static func picture(width: Int = 97, height: Int = 61) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * context.bytesPerRow + x * 4
                var alpha = 255
                if y > height * 2 / 3 { alpha = 40 + (x * 3) % 200 }
                if x < 6 && y < 6 { alpha = 0 }
                let r = (x * 7 + y * 3) % 256, g = (x * x + y * 5) % 256, b = (x * 2 + y * y) % 256
                bytes[p] = UInt8(r * alpha / 255); bytes[p + 1] = UInt8(g * alpha / 255)
                bytes[p + 2] = UInt8(b * alpha / 255); bytes[p + 3] = UInt8(alpha)
            }
        }
        return try #require(context.makeImage())
    }

    /// FNV-1a over each row's pixels (not its padding).
    static func hash(_ image: CGImage) throws -> UInt64 {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for y in 0..<image.height {
            for i in 0..<(image.width * 4) {
                hash = (hash ^ UInt64(bytes[y * image.bytesPerRow + i])) &* 0x100_0000_01b3
            }
        }
        return hash
    }

    static func light(_ settings: inout CameraRawSettings) {
        settings.temperature = 20; settings.tint = -10; settings.exposure = 0.6; settings.contrast = 25
        settings.highlights = -40; settings.shadows = 35; settings.whites = 10; settings.blacks = -15
        settings.vibrance = 30; settings.saturation = -12
    }

    static func effects(_ settings: inout CameraRawSettings) {
        settings.texture = 35; settings.clarity = -25; settings.dehaze = 20
        settings.glow = 40; settings.glowStyle = .halation; settings.glowSpread = 30
        settings.vignetteAmount = -30; settings.vignetteRoundness = 20
    }

    @Test(arguments: [
        ("light", UInt64(13877237661017904764)), ("light, highlight clipping", UInt64(1047115404880164632)), ("light, shadow clipping", UInt64(9026041150702649921)),
        ("effects", UInt64(2862192429195149811)), ("detail", UInt64(5617087740119641898)),
    ])
    func kernelsGiveTheSamePixels(_ name: String, _ expected: UInt64) throws {
        var settings = CameraRawSettings()
        var clipping: CameraRawClipping?
        switch name {
        case "light": Self.light(&settings)
        case "light, highlight clipping": Self.light(&settings); clipping = .highlights
        case "light, shadow clipping": Self.light(&settings); clipping = .shadows
        case "effects": Self.effects(&settings)
        default:
            settings.detail.sharpenAmount = 80; settings.detail.sharpenMasking = 30
            settings.detail.noiseLuminance = 40; settings.detail.noiseColor = 30
        }
        let result = try settings.apply(try Self.picture(), clipping: clipping)
        let hash = try Self.hash(result)
        #expect(hash == expected, "\(name): \(hash)")
    }

    /// An opaque picture the size of the preview cap, like a photo.
    static func photo() throws -> CGImage {
        let width = 2048, height = 1365
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * context.bytesPerRow + x * 4
                bytes[p] = UInt8((x / 8 + y) % 256); bytes[p + 1] = UInt8((x + y / 4) % 256)
                bytes[p + 2] = UInt8((x * y / 64) % 256); bytes[p + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// The best of three runs, in milliseconds: the least disturbed by whatever else the machine is doing.
    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let start = ContinuousClock.now
            try body()
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return best
    }



    /// Blurs wider than the picture, on a single pixel, a single row and a single column.
    @Test(arguments: [(1, 1, UInt64(5558979605539197941)), (97, 1, UInt64(15426182781399563245)), (1, 61, UInt64(5994485904874808949))])
    func effectsOnTinyPictures(_ width: Int, _ height: Int, _ expected: UInt64) throws {
        var settings = CameraRawSettings()
        Self.effects(&settings)
        settings.detail.noiseLuminance = 60; settings.detail.sharpenAmount = 50
        let hash = try Self.hash(try settings.apply(try Self.picture(width: width, height: height)))
        #expect(hash == expected, "\(width) × \(height): \(hash)")
    }

}

/// How long the kernels take, one test at a time: run side by side, each would get only part of the cores.
@Suite(.serialized)
struct CameraRawTimingTests {
    /// Code coverage counts every branch in counters all threads share, so under it threads wait on each other and
    /// timings say nothing about the app. Xcode points `LLVM_PROFILE_FILE` at /dev/null when coverage is off.
    static let measuresTime = ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"].map { $0 == "/dev/null" } ?? true

    /// Dragging a Light or Color slider redraws this much for every step. On one core it took about 370 ms.
    @Test(.enabled(if: measuresTime, "timings under code coverage don't reflect the app"))
    func lightAndColorKeepUpWithASlider() throws {
        var settings = CameraRawSettings()
        CameraRawSpeedTests.light(&settings)
        let photo = try CameraRawSpeedTests.photo()
        let time = try CameraRawSpeedTests.milliseconds { _ = try settings.apply(photo) }
        // Alone it takes about 50 ms; the limit leaves room for other tests running at the same time.
        #expect(time < 200, "\(Int(time)) ms")
    }

    /// Texture, Clarity and Dehaze redraw this much for every slider step. On one core it took about 160 ms.
    @Test(.enabled(if: measuresTime, "timings under code coverage don't reflect the app"))
    func effectsKeepUpWithASlider() throws {
        var settings = CameraRawSettings()
        settings.texture = 35; settings.clarity = -25; settings.dehaze = 20
        let photo = try CameraRawSpeedTests.photo()
        let time = try CameraRawSpeedTests.milliseconds { _ = try settings.apply(photo) }
        #expect(time < 100, "\(Int(time)) ms")
    }
}
