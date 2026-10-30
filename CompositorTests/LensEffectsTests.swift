import CoreGraphics
import Testing
@testable import Compositor

/// Filter › Lens Effects, on a dark picture with one small white light in the middle.
struct LensEffectsTests {
    private let width = 400, height = 240

    private func night() throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 190, y: 110, width: 20, height: 20))
        return try #require(context.makeImage())
    }

    private func run(_ change: (inout LensEffectSettings) -> Void) throws -> CGImage {
        var settings = FilterSettings()
        change(&settings.lens)
        return try PixelFilter.run(FilterJob(kind: .lensEffects, image: try night(), settings: settings, scale: 1,
                                           selection: nil, mapping: .identity))
    }

    /// Red, green and blue at a pixel, rows top-down.
    private func color(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = y * context.bytesPerRow + x * 4
        return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
    }

    @Test func anamorphicFlareStreaksSidewaysInBlue() throws {
        let original = try night(), flared = try run { $0.effect = .anamorphicFlare; $0.flareAmount = 80 }
        let beside = try color(flared, 300, 120), above = try color(flared, 200, 30)
        #expect(beside[2] > (try color(original, 300, 120))[2] + 10, "the streak reaches across: \(beside)")
        #expect(beside[2] > beside[0], "and is blue: \(beside)")
        #expect(above == (try color(original, 200, 30)), "but not up: \(above)")
    }

    @Test func anamorphicFlareKeepsTheLightsColorWithoutBlue() throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A light just short of white, red-tinged, as a hot tail light is.
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 192, y: 112, width: 16, height: 16))
        let light = try #require(context.makeImage())
        var settings = FilterSettings()
        settings.lens.effect = .anamorphicFlare
        settings.lens.flareBlue = 0
        settings.lens.flareAmount = 80
        let flared = try PixelFilter.run(FilterJob(kind: .lensEffects, image: light, settings: settings, scale: 1, selection: nil, mapping: .identity))
        let beside = try color(flared, 280, 120)
        #expect(beside[0] > 20 && beside[0] >= beside[2], "a streak the light's color, not blue: \(beside)")
    }

    @Test func anamorphicThresholdDecidesWhichLightsFlare() throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A light short of white, as a backlight or a bulb in daylight is.
        context.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 192, y: 112, width: 16, height: 16))
        let light = try #require(context.makeImage())
        func streak(_ threshold: Double) throws -> Int {
            var settings = FilterSettings()
            settings.lens.effect = .anamorphicFlare
            settings.lens.threshold = threshold
            let flared = try PixelFilter.run(FilterJob(kind: .lensEffects, image: light, settings: settings, scale: 1, selection: nil, mapping: .identity))
            return (try color(flared, 280, 120))[2] - (try color(light, 280, 120))[2]
        }
        #expect(try streak(75) > 8, "below the light: it flares")
        #expect(try streak(95) <= 1, "above it: nothing")
    }

    @Test func starburstSpikesAlongItsAngle() throws {
        let original = try night(), starred = try run { $0.effect = .starburst; $0.starAngle = 0; $0.starPoints = 4; $0.starAmount = 100 }
        // Four points at 0°: spikes left, right, up and down; none on the diagonal.
        #expect((try color(starred, 240, 120))[1] > (try color(original, 240, 120))[1] + 10)
        #expect((try color(starred, 200, 70))[1] > (try color(original, 200, 70))[1] + 10)
        #expect((try color(starred, 240, 70))[1] <= (try color(original, 240, 70))[1] + 2)
    }

    @Test func mistGlowsAroundTheLightWithoutBrighteningThePicture() throws {
        let original = try night(), misted = try run { $0.effect = .mist; $0.mistStrength = 80 }
        #expect((try color(misted, 225, 120))[1] > (try color(original, 225, 120))[1] + 5, "a halo beside the light")
        #expect((try color(misted, 10, 10))[1] <= (try color(original, 10, 10))[1] + 3, "far corners barely lift")
    }

    @Test func prismGhostsASharpCopy() throws {
        let original = try night()
        // Pushed left by a quarter of the width: the light's copy lands 100 pixels left of it, and stays crisp.
        let ghosted = try run { $0.effect = .prism; $0.prismAngle = 180; $0.prismOffset = 25; $0.prismCopies = 1; $0.prismAmount = 100 }
        #expect((try color(ghosted, 100, 120))[1] > (try color(original, 100, 120))[1] + 20)
        #expect((try color(ghosted, 70, 120)) == (try color(original, 70, 120)), "a sharp copy, not a smear")
        #expect((try color(ghosted, 300, 120)) == (try color(original, 300, 120)), "the other side is untouched")
    }

    @Test func prismBothWaysEchoesOnEachSide() throws {
        let original = try night()
        func echo(_ bothWays: Bool) throws -> (left: Int, right: Int) {
            let image = try run { $0.effect = .prism; $0.prismAngle = 180; $0.prismOffset = 25; $0.prismCopies = 1; $0.prismAmount = 100; $0.prismBothWays = bothWays }
            return ((try color(image, 100, 120))[1] - (try color(original, 100, 120))[1],
                    (try color(image, 300, 120))[1] - (try color(original, 300, 120))[1])
        }
        let one = try echo(false), both = try echo(true)
        #expect(one.left > 20 && one.right == 0)
        #expect(both.left > 20 && both.right > 20)
    }

    @Test func prismFringeSplitsTheCopysColorsOrKeepsThemCrisp() throws {
        let original = try night()
        // The copy lands 100 pixels left, at 90–110: how many pixels across its red and its blue land apart.
        func split(_ fringe: Double) throws -> Int {
            let image = try run { $0.effect = .prism; $0.prismAngle = 180; $0.prismOffset = 25; $0.prismCopies = 1; $0.prismAmount = 100; $0.prismFringe = fringe }
            var apart = 0
            for x in 80...120 {
                let now = try color(image, x, 120)
                if (now[0] > 128) != (now[2] > 128) { apart += 1 }
            }
            return apart
        }
        #expect(try split(0) == 0, "crisp")
        #expect(try split(100) >= 4, "fringed")
    }

    @Test func prismCopiesEchoFartherOut() throws {
        let original = try night()
        // Copies 40 pixels apart, leftwards from the light at 190–210: the third lands around 80–90.
        func echo(_ copies: Double) throws -> Int {
            let image = try run { $0.effect = .prism; $0.prismCopies = copies; $0.prismOffset = 10; $0.prismAmount = 100 }
            return (try color(image, 85, 120))[1] - (try color(original, 85, 120))[1]
        }
        #expect(try echo(1) <= 2)
        #expect(try echo(3) > 10)
    }

    @Test func bokehOpensTheLightIntoABrightDisc() throws {
        let original = try night()
        // A radius of 3% of 400 pixels, 12: inside it the light spreads evenly; well past it, nothing.
        let blurred = try run { $0.effect = .bokeh; $0.bokehRadius = 3; $0.bokehRing = 0 }
        #expect((try color(blurred, 200, 135))[1] > (try color(original, 200, 135))[1] + 40, "the disc reaches past the light")
        #expect((try color(blurred, 200, 160))[1] <= (try color(original, 200, 160))[1] + 2, "but not far past its radius")
    }

    @Test func ovalBokehIsTallerThanWide() throws {
        let original = try night()
        let oval = try run { $0.effect = .bokeh; $0.bokehRadius = 4; $0.bokehShape = .oval }
        // Radius 16 from a 20-pixel light at 190–210, 110–130: 34 pixels out sideways is past it, but not upwards.
        let up = (try color(oval, 200, 120 - 34))[1] - (try color(original, 200, 120 - 34))[1]
        let side = (try color(oval, 200 + 34, 120))[1] - (try color(original, 200 + 34, 120))[1]
        #expect(up > side + 10, "up \(up), sideways \(side)")
    }

    @Test func prismWithoutOffsetStillApplies() {
        var settings = LensEffectSettings()
        settings.effect = .prism
        settings.prismOffset = 0
        // Its copies still fringe the picture, as the preview shows, so OK has to keep them.
        #expect(!settings.isIdentity)
    }

    @Test func noAmountIsNothingToDo() {
        for effect in LensEffect.allCases {
            var settings = LensEffectSettings()
            settings.effect = effect
            settings.flareAmount = 0; settings.starAmount = 0; settings.mistStrength = 0; settings.prismAmount = 0
            #expect(settings.isIdentity == (effect != .bokeh), "Bokeh is always a full lens blur")
            settings.flareAmount = 50; settings.starAmount = 50; settings.mistStrength = 50; settings.prismAmount = 50
            #expect(!settings.isIdentity)
        }
    }
}
