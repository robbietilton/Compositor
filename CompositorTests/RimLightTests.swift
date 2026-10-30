import CoreGraphics
import Testing
@testable import Compositor

/// Filter › Rim Light, on a figure standing in front of a dark backdrop.
struct RimLightTests {
    private let width = 600, height = 400

    private func figure() throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A head and shoulders, rows bottom-up here.
        context.setFillColor(CGColor(red: 0.55, green: 0.42, blue: 0.35, alpha: 1))
        context.fillEllipse(in: CGRect(x: 250, y: 220, width: 100, height: 120))
        context.fill(CGRect(x: 285, y: 170, width: 30, height: 60))
        context.fillEllipse(in: CGRect(x: 170, y: -120, width: 260, height: 310))
        return try #require(context.makeImage())
    }

    /// Red, green and blue at a pixel, rows top-down.
    private func color(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let at = y * context.bytesPerRow + x * 4
        return [Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2])]
    }

    /// Where the subject Rim Light lights starts and ends along row `y`: Vision's own outline of it, which on a drawing
    /// as flat as this one sits a little outside the shapes.
    private func subjectSpan(_ image: CGImage, row y: Int) throws -> (left: Int, right: Int) {
        let mask = try RimLighting.subject(image)
        let inside = try (0..<width).filter { try color(mask, $0, y)[0] > 128 }
        return (try #require(inside.first), try #require(inside.last))
    }

    @Test func aLightFromTheLeftCatchesTheLeftEdgeOnly() throws {
        let original = try figure()
        var settings = FilterSettings()
        settings.rimLight.lights = [RimLight(angle: 180, color: AdjustmentColor(red: 1, green: 1, blue: 1), strength: 80, width: 30)]
        let lit = try PixelFilter.run(FilterJob(kind: .rimLight, image: original, settings: settings, scale: 1, selection: nil, mapping: .identity))
        // Just inside the head's left and right edges, and its middle, which faces the camera.
        let span = try subjectSpan(original, row: 110)
        let left = try color(lit, span.left + 4, 110)[1] - color(original, span.left + 4, 110)[1]
        let right = try color(lit, span.right - 4, 110)[1] - color(original, span.right - 4, 110)[1]
        let middle = try color(lit, (span.left + span.right) / 2, 110)[1] - color(original, (span.left + span.right) / 2, 110)[1]
        #expect(left > 25, "the edge facing the light: \(left)")
        #expect(right <= 3, "the edge facing away: \(right)")
        #expect(middle <= 3, "the front, which light from behind doesn't reach: \(middle)")
        #expect(try color(lit, 20, 20) == color(original, 20, 20), "the backdrop far from the subject")
    }

    @Test func chokeHoldsTheLightFurtherIn() throws {
        let original = try figure()
        func lift(_ choke: Double) throws -> Int {
            var settings = FilterSettings()
            settings.rimLight.lights = [RimLight(angle: 180, color: AdjustmentColor(red: 1, green: 1, blue: 1), strength: 15, width: 100,
                                                 choke: choke)]
            let lit = try PixelFilter.run(FilterJob(kind: .rimLight, image: original, settings: settings, scale: 1, selection: nil, mapping: .identity))
            // About two thirds of the way to the light's Width (19 pixels here) in from the head's left edge.
            let x = try subjectSpan(original, row: 110).left + 12
            return try color(lit, x, 110)[1] - color(original, x, 110)[1]
        }
        let held = try lift(100), feathered = try lift(0)
        #expect(held > feathered + 10, "held \(held), feathered \(feathered)")
    }

    @Test func glowLightsTheAirBesideTheLitEdgeAndLeavesTheSubject() throws {
        let original = try figure()
        func lit(glow: Double) throws -> CGImage {
            var settings = FilterSettings()
            settings.rimLight.glow = glow
            settings.rimLight.lights = [RimLight(angle: 180, color: AdjustmentColor(red: 1, green: 1, blue: 1), strength: 80, width: 30)]
            return try PixelFilter.run(FilterJob(kind: .rimLight, image: original, settings: settings, scale: 1, selection: nil, mapping: .identity))
        }
        let none = try lit(glow: 0), glowing = try lit(glow: 100)
        let span = try subjectSpan(original, row: 110)
        // Beside the lit edge, outside the subject, and in the head's middle.
        let beside = try color(glowing, span.left - 6, 110)[1] - color(none, span.left - 6, 110)[1]
        let middle = try color(glowing, (span.left + span.right) / 2, 110)[1] - color(none, (span.left + span.right) / 2, 110)[1]
        #expect(beside > 10, "the air beside the lit edge: \(beside)")
        #expect(abs(middle) <= 2, "the subject keeps only its rims: \(middle)")
        #expect(try color(none, span.left - 6, 110) == color(original, span.left - 6, 110), "no glow at 0")
    }

    @Test func glowWrapsALittleWayInAcrossTheLitEdge() throws {
        let original = try figure()
        func lit(glow: Double) throws -> CGImage {
            var settings = FilterSettings()
            settings.rimLight.glow = glow
            settings.rimLight.lights = [RimLight(angle: 180, color: AdjustmentColor(red: 1, green: 1, blue: 1), strength: 30, width: 0, choke: 100)]
            return try PixelFilter.run(FilterJob(kind: .rimLight, image: original, settings: settings, scale: 1, selection: nil, mapping: .identity))
        }
        let none = try lit(glow: 0), glowing = try lit(glow: 100)
        // Just inside the lit edge, past where the rim itself reaches.
        let x = try subjectSpan(original, row: 110).left + 4
        let wrap = try color(glowing, x, 110)[1] - color(none, x, 110)[1]
        #expect(wrap > 4, "the glow across the edge: \(wrap)")
    }

    @Test func theSubjectIsFoundOnceAndKept() throws {
        let original = try figure()
        _ = try RimLighting.subject(original)
        #expect(RimLighting.hasSubject(for: original))
        #expect(!RimLighting.hasSubject(for: try figure()), "another image's subject isn't this one's")
    }

    @Test func aRemovedLightCanStillBeAskedForWithoutReachingPastTheList() {
        var settings = RimLightSettings()
        settings.lights.append(settings.nextLight)
        let removed = settings.lights[1].id
        settings.lights.removeAll { $0.id == removed }
        // A control still drawn for it reads a default and its change goes nowhere.
        #expect(settings[light: removed].strength == 50)
        settings[light: removed].strength = 10
        #expect(settings.lights.count == 1 && settings.lights[0].strength == 50)
    }

    @Test func eachLightWrapsAsFarAsItsOwnWidth() throws {
        let original = try figure()
        func lift(_ width: Double) throws -> Int {
            var settings = FilterSettings()
            settings.rimLight.lights = [RimLight(angle: 180, color: AdjustmentColor(red: 1, green: 1, blue: 1), strength: 80, width: width)]
            let lit = try PixelFilter.run(FilterJob(kind: .rimLight, image: original, settings: settings, scale: 1, selection: nil, mapping: .identity))
            // Well inside the head's left edge.
            let x = try subjectSpan(original, row: 110).left + 14
            return try color(lit, x, 110)[1] - color(original, x, 110)[1]
        }
        #expect(try lift(100) > lift(0) + 10)
    }
}
