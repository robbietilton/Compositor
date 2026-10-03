import AppKit
import Testing
@testable import Compositor

@MainActor
struct HueSaturationTests {
    /// A 40×20 canvas: left half pure red, right half mid gray, with a half-transparent strip.
    private func makeSession() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        // Replace, so the strip really is half transparent rather than blended onto the colors.
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 16, width: 40, height: 4))
        context.setBlendMode(.normal)
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Colors"))
        return session
    }
    private func pixel(_ session: EditorSession, x: Int, y: Int) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }
    /// The color cube is interpolated, so allow a few levels.
    private func near(_ value: [Int], _ target: [Int], _ tolerance: Int = 8) -> Bool {
        zip(value, target).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private func apply(_ session: EditorSession, _ settings: HueSaturationSettings) async {
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
    }

    @Test func defaultsAreAnExactNoOp() async throws {
        let session = try makeSession()
        let before = session.document
        let count = session.history.undoCount
        session.beginHueSaturation()
        #expect(session.hueSaturation != nil && !session.canEditLayers) // Other edits wait.
        session.updateHueSaturation(HueSaturationSettings(), preview: true)
        await session.commitHueSaturation()
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.hueSaturation == nil && session.canEditLayers)
    }

    @Test func hueRotatesSaturationAndLightnessFollowPhotoshopRanges() async throws {
        let session = try makeSession()
        await apply(session, HueSaturationSettings(hue: 120))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))   // Red → green.
        #expect(near(try await pixel(session, x: 30, y: 5), [128, 128, 128, 255])) // Gray unchanged.
        session.undo()

        await apply(session, HueSaturationSettings(saturation: -100))
        let gray = try await pixel(session, x: 5, y: 5)
        #expect(gray[0] == gray[1] && gray[1] == gray[2] && gray[3] == 255)
        session.undo()

        await apply(session, HueSaturationSettings(lightness: 100))
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 255, 255, 255]))
        session.undo()

        await apply(session, HueSaturationSettings(lightness: -100))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 0, 0, 255]))
    }

    @Test func colorizeGivesEverythingOneHueAndKeepsAlpha() async throws {
        let session = try makeSession()
        await apply(session, HueSaturationSettings(hue: 240, saturation: 100, lightness: 0, colorize: true))
        let left = try await pixel(session, x: 5, y: 5), right = try await pixel(session, x: 30, y: 5)
        #expect(left[2] > left[0] && right[2] > right[0])   // Both now blue-ish.
        #expect(left[3] == 255)
        // The half-transparent strip keeps its alpha.
        let strip = try await pixel(session, x: 5, y: 18)
        #expect(abs(strip[3] - 128) <= 2)
    }

    @Test func adjustmentStaysInsideTheSelectionAndIsOneUndoStep() async throws {
        let session = try makeSession()
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 20), transform: nil),
                               mode: .replace, name: "Select")
        let count = session.history.undoCount
        await apply(session, HueSaturationSettings(hue: 120))
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Hue/Saturation")
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))     // Inside: rotated.
        #expect(near(try await pixel(session, x: 15, y: 5), [255, 0, 0, 255]))    // Outside: untouched.
        session.undo()
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 0, 0, 255]))
    }

    /// Previews are drawn on the canvas from a downscaled copy; the document is untouched
    /// until OK, so these read the preview image rather than an export.
    @Test func previewIsLiveDoesNotTouchTheDocumentAndNeverAccumulates() async throws {
        let session = try makeSession()
        let before = session.document
        let count = session.history.undoCount
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        await session.hueSaturationTask?.value
        let edit = try #require(session.hueSaturation)
        #expect(near(try previewPixel(edit, x: 5, y: 5), [0, 255, 0, 255]))
        #expect(session.document == before && session.history.undoCount == count)
        // Dragging further starts from the original each time, never stacking.
        session.updateHueSaturation(HueSaturationSettings(hue: 240), preview: true)
        await session.hueSaturationTask?.value
        #expect(near(try previewPixel(edit, x: 5, y: 5), [0, 0, 255, 255]))
        // Preview off drops back to the layer's own pixels.
        session.updateHueSaturation(HueSaturationSettings(hue: 240), preview: false)
        #expect(edit.previewImage(for: edit.layerID) == nil)
        session.cancelHueSaturation()
        #expect(session.document == before && session.hueSaturation == nil)
        // OK renders at full size and only then changes the layer.
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 120), preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        #expect(session.document?.layers.first?.asset?.image.width == before?.layers.first?.asset?.image.width)
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 255, 0, 255]))
    }

    /// A pixel of the live preview image, which may be smaller than the layer.
    private func previewPixel(_ edit: HueSaturationEdit, x: Int, y: Int) throws -> [Int] {
        let image = try #require(edit.previewImage(for: edit.layerID))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let index = (y * image.width + x) * 4
        return (0..<4).map { Int(bytes[index + $0]) }
    }

    /// A 40×20 canvas: left half pure red, right half pure blue, both opaque.
    private func redAndBlue() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "RedBlue"))
        return session
    }

    /// A press on the band's handles takes the nearest of the four, round the hue circle, however far it is; a tie goes
    /// to the first.
    @Test func thePressTakesTheNearestHandle() {
        let reds = ColorRange.reds.defaultBand // 315 / 345 / 15 / 45.
        #expect(reds.nearestHandle(to: 5) == 2)
        #expect(reds.nearestHandle(to: 350) == 1)
        #expect(reds.nearestHandle(to: 330) == 0)
        #expect(reds.nearestHandle(to: 120) == 3)
    }

    @Test func bandWeightsRampThroughFalloffAndWrapAround() {
        let reds = ColorRange.reds.defaultBand // 315 / 345 / 15 / 45, wrapping past 0.
        #expect(reds.weight(of: 0) == 1 && reds.weight(of: 345) == 1 && reds.weight(of: 15) == 1)
        #expect(abs(reds.weight(of: 330) - 0.5) < 0.001)   // Halfway up the shoulder.
        #expect(abs(reds.weight(of: 30) - 0.5) < 0.001)    // Halfway down the far shoulder.
        #expect(reds.weight(of: 315) == 0 && reds.weight(of: 45) == 0 && reds.weight(of: 180) == 0)
        #expect(ColorRange.master.defaultBand.weight(of: 123) == 1)
        // Handles keep their order: crossing moves are refused.
        var band = ColorRange.greens.defaultBand
        band.setHandle(1, to: 200) // rangeStart past rangeEnd.
        #expect(band == ColorRange.greens.defaultBand)
        band.setHandle(1, to: 110)
        #expect(band.rangeStart == 110)
    }

    @Test func colorRangesAdjustIndependently() async throws {
        let session = try redAndBlue()
        var settings = HueSaturationSettings(hue: 60, range: .reds)
        settings.adjustments[.blues] = RangeAdjustment(saturation: -100)
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        let red = try await pixel(session, x: 5, y: 5), blue = try await pixel(session, x: 30, y: 5)
        #expect(near(red, [255, 255, 0, 255]))              // Reds rotated to yellow.
        #expect(blue[0] == blue[1] && blue[1] == blue[2])   // Blues desaturated to gray.
    }

    @Test func rangesLeaveOtherHuesAloneAndInvertFlipsTheBand() async throws {
        let session = try redAndBlue()
        let before = try await pixel(session, x: 30, y: 5)
        await apply(session, HueSaturationSettings(lightness: -100, range: .reds))
        #expect(near(try await pixel(session, x: 5, y: 5), [0, 0, 0, 255]))  // Reds → black.
        #expect(near(try await pixel(session, x: 30, y: 5), before))         // Blues untouched.
        session.undo()

        var inverted = HueSaturationSettings(lightness: -100, range: .reds)
        inverted.invertRange = true
        await apply(session, inverted)
        #expect(near(try await pixel(session, x: 5, y: 5), [255, 0, 0, 255])) // Reds untouched.
        #expect(near(try await pixel(session, x: 30, y: 5), [0, 0, 0, 255]))  // Everything else → black.
    }

    @Test func slidersEditTheSelectedRangeAndTheAfterBarFollowsHueShifts() {
        var settings = HueSaturationSettings()
        settings.hue = 30                       // Master.
        settings.range = .greens
        #expect(settings.hue == 0)              // Greens start untouched.
        settings.hue = -40
        #expect(settings.adjustments[.master]?.hue == 30 && settings.adjustments[.greens]?.hue == -40)
        settings.range = .master
        #expect(settings.hue == 30 && !settings.isIdentity)
        // The "after" spectrum shifts hues inside a band and leaves far-away hues alone.
        var greensOnly = HueSaturationSettings(hue: 60, range: .greens)
        greensOnly.adjustments[.master] = RangeAdjustment()
        #expect(abs(HueSaturationFilter.shiftedHue(120, settings: greensOnly) - 180) < 0.001)
        #expect(abs(HueSaturationFilter.shiftedHue(0, settings: greensOnly) - 0) < 0.001)
    }

    @Test func eyedroppersRecenterWidenAndNarrowTheBand() async throws {
        let session = try redAndBlue() // Red at hue 0 on the left, blue at 240 on the right.
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(hue: 10, range: .greens), preview: false)
        session.hueSampleMode = .replace
        session.sampleHueRange(at: CGPoint(x: 5, y: 5))
        var band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 0) == 1 && band.weight(of: 120) == 0) // Centered on red.

        session.hueSampleMode = .add
        session.sampleHueRange(at: CGPoint(x: 30, y: 5))
        band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 240) == 1 && band.weight(of: 0) == 1) // Blue folded in.

        session.hueSampleMode = .remove
        session.sampleHueRange(at: CGPoint(x: 30, y: 5))
        band = try #require(session.hueSaturation).settings.band
        #expect(band.weight(of: 240) == 0)                            // Blue pushed back out.
        session.cancelHueSaturation()
        #expect(session.hueSampleMode == nil)
    }

    @Test func targetedAdjustmentPicksTheRangeUnderTheCursor() async throws {
        let session = try redAndBlue()
        session.beginHueSaturation()
        session.hueTargeting = true
        #expect(session.beginHueTargeting(at: CGPoint(x: 30, y: 5))) // Blue half.
        #expect(session.hueSaturation?.settings.range == .blues)
        session.dragHueTargeting(byViewDelta: 60, adjustsHue: false)
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.saturation == 30)
        // Each drag is measured from where it started, so it never accumulates.
        session.dragHueTargeting(byViewDelta: 20, adjustsHue: false)
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.saturation == 10)
        session.dragHueTargeting(byViewDelta: -40, adjustsHue: true) // Command holds hue.
        #expect(session.hueSaturation?.settings.adjustments[.blues]?.hue == -20)
        session.endHueTargeting()
        session.cancelHueSaturation()
        #expect(!session.hueTargeting)
    }

    @Test func samplingNeedsAColorRangeAndAColorfulPixel() throws {
        let session = try redAndBlue()
        session.beginHueSaturation()
        let untouched = try #require(session.hueSaturation).settings.band
        session.hueSampleMode = .replace
        session.sampleHueRange(at: CGPoint(x: 5, y: 5))   // Master is selected: nothing to retarget.
        #expect(session.hueSaturation?.settings.band == untouched)
        // A gray pixel has no hue to sample.
        let gray = try makeSession() // Right half is mid gray.
        gray.beginHueSaturation()
        gray.updateHueSaturation(HueSaturationSettings(range: .reds), preview: false)
        let before = try #require(gray.hueSaturation).settings.band
        gray.hueSampleMode = .replace
        gray.sampleHueRange(at: CGPoint(x: 30, y: 5))
        #expect(gray.hueSaturation?.settings.band == before)
    }

    /// Photoshop raises saturation by dividing by what's left: +50 doubles it, +100 takes any color all the way.
    @Test func positiveSaturationMatchesPhotoshop() {
        #expect(abs(HueSaturationFilter.adjustedSaturation(0.2, by: 50) - 0.4) < 1e-9)
        #expect(abs(HueSaturationFilter.adjustedSaturation(0.3, by: 62) - 0.3 / 0.38) < 1e-9)
        #expect(HueSaturationFilter.adjustedSaturation(0.1, by: 100) == 1)
        #expect(HueSaturationFilter.adjustedSaturation(0.8, by: 50) == 1)
        #expect(HueSaturationFilter.adjustedSaturation(0, by: 100) == 0)
        #expect(abs(HueSaturationFilter.adjustedSaturation(0.6, by: -50) - 0.3) < 1e-9)
    }
}
