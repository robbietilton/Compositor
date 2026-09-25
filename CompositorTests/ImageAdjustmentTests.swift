import AppKit
import Testing
@testable import Compositor

@MainActor
struct ImageAdjustmentTests {
    /// A width × height image filled with one straight sRGB color.
    private func image(width: Int = 4, height: Int = 4, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    private func gray(width: Int = 4, height: Int = 4, alpha: CGFloat = 1) throws -> CGImage {
        try image(width: width, height: height, red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: alpha)
    }
    /// Straight RGBA bytes of every pixel, top row first.
    private func pixels(_ image: CGImage) throws -> [[Int]] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var result: [[Int]] = []
        for i in 0..<image.width * image.height {
            let a = Int(data[i * 4 + 3])
            var pixel: [Int] = []
            for c in 0..<3 {
                let value: Int = a == 0 ? 0 : min(255, (Int(data[i * 4 + c]) * 255 + a / 2) / a)
                pixel.append(value)
            }
            pixel.append(a)
            result.append(pixel)
        }
        return result
    }

    @Test func exposureWorksInLinearLightWithOffsetAndGamma() throws {
        let input = try gray()
        #expect(try pixels(ExposureSettings().apply(input)) == pixels(input), "defaults change nothing")
        let brighter = try pixels(ExposureSettings(exposure: 1).apply(input))[0]
        #expect(abs(brighter[0] - 176) <= 2, "+1 stop doubles linear light: \(brighter)")
        #expect(brighter[0] == brighter[2])
        let lifted = try pixels(ExposureSettings(gamma: 2).apply(input))[0]
        #expect(abs(lifted[0] - 181) <= 2, "gamma 2 takes the square root of linear light: \(lifted)")
        let black = try image(red: 0, green: 0, blue: 0)
        let offset = try pixels(ExposureSettings(offset: 0.1).apply(black))[0]
        #expect(abs(offset[0] - 89) <= 2, "offset adds linear light: \(offset)")
        let translucent = try gray(alpha: 0.5)
        #expect(try pixels(ExposureSettings(exposure: 1).apply(translucent))[0][3] == pixels(translucent)[0][3], "alpha kept")
    }

    @Test func gradientMapColorsByBrightnessAndReverses() throws {
        var settings = GradientMapSettings(shadows: AdjustmentColor(red: 1, green: 0, blue: 0),
                                           highlights: AdjustmentColor(red: 0, green: 0, blue: 1))
        #expect(try pixels(settings.apply(image(red: 0, green: 0, blue: 0)))[0] == [255, 0, 0, 255])
        #expect(try pixels(settings.apply(image(red: 1, green: 1, blue: 1)))[0] == [0, 0, 255, 255])
        let middle = try pixels(settings.apply(gray()))[0]
        let red = middle[0], green = middle[1], blue = middle[2]
        #expect(abs(red - 127) <= 2, "\(middle)")
        #expect(abs(blue - 128) <= 2, "\(middle)")
        #expect(green == 0, "\(middle)")
        let translucent = try pixels(settings.apply(image(red: 1, green: 1, blue: 1, alpha: 0.5)))[0]
        let clearBlue = translucent[2], clearRed = translucent[0], clearAlpha = translucent[3]
        #expect(clearBlue >= 250, "\(translucent)")
        #expect(clearRed <= 5, "\(translucent)")
        #expect(abs(clearAlpha - 128) <= 1, "alpha kept: \(translucent)")
        settings.reversed = true
        #expect(try pixels(settings.apply(image(red: 0, green: 0, blue: 0)))[0] == [0, 0, 255, 255])
    }

    @Test func grainIsFixedInDocumentSpaceAndLeavesTransparencyAlone() throws {
        let settings = GrainSettings(amount: 60, size: 2, roughness: 40, seed: 7)
        let whole = try pixels(settings.apply(gray(width: 40, height: 40)))
        #expect(Set(whole.map { $0[0] }).count > 5, "grain varies the brightness")
        let neutral = whole.allSatisfy { (pixel: [Int]) -> Bool in pixel[0] == pixel[1] && pixel[1] == pixel[2] }
        #expect(neutral, "the same change on every channel")
        // A 20 × 20 piece drawn at its place in the document gets the same grain as that part of the whole.
        let part = try pixels(settings.apply(gray(width: 20, height: 20), origin: CGPoint(x: 10, y: 10)))
        var crop: [[Int]] = []
        for y in 0..<20 { for x in 0..<20 { crop.append(whole[(y + 10) * 40 + x + 10]) } }
        #expect(part == crop, "grain must not shift when only part of the canvas redraws")
        var reseeded = settings
        reseeded.seed = 8
        #expect(try pixels(reseeded.apply(gray(width: 40, height: 40))) != whole, "another seed, another pattern")
        #expect(try pixels(GrainSettings(amount: 0).apply(gray())) == pixels(gray()), "no amount, no change")
        let cleared = try pixels(settings.apply(gray(alpha: 0)))
        #expect(cleared.allSatisfy { (pixel: [Int]) -> Bool in pixel[3] == 0 }, "clear pixels stay clear")
    }

    @Test func grainSizeControlsParticleScaleEvenWithRoughness() throws {
        let source = try gray(width: 64, height: 64)
        let small = try pixels(GrainSettings(amount: 70, size: 1, roughness: 70, seed: 17).apply(source))
        let large = try pixels(GrainSettings(amount: 70, size: 12, roughness: 70, seed: 17).apply(source))
        func neighboringDifference(_ values: [[Int]]) -> Double {
            var total = 0, count = 0
            for y in 0..<64 { for x in 1..<64 {
                total += abs(values[y * 64 + x][0] - values[y * 64 + x - 1][0]); count += 1
            } }
            return Double(total) / Double(count)
        }
        #expect(neighboringDifference(large) < neighboringDifference(small) * 0.7,
                "larger grain should form visibly larger, more coherent particles")
    }

    @Test func settingsSaveAndOlderAdjustmentsStillOpen() throws {
        let levels = LayerAdjustment(kind: .levels)
        let data = try JSONEncoder().encode(levels)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("exposureSettings"), "an existing kind saves exactly as before")
        #expect(!json.contains("gradientMapSettings"))
        #expect(!json.contains("grainSettings"))
        #expect(try JSONDecoder().decode(LayerAdjustment.self, from: data) == levels)
        var grain = LayerAdjustment(kind: .grain)
        grain.grain = GrainSettings(amount: 40, size: 3, roughness: 10, seed: 9)
        let decoded = try JSONDecoder().decode(LayerAdjustment.self, from: JSONEncoder().encode(grain))
        #expect(decoded == grain)
        #expect(decoded.isValid)
        var broken = LayerAdjustment(kind: .exposure)
        broken.exposure.gamma = 0
        #expect(!broken.isValid)
    }

    @Test func newAdjustmentLayersStartFromThePaletteRenderAndEditInThePanel() async throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        let base = try gray(width: 20, height: 20)
        session.insert(ImportedImage(image: base, thumbnail: base, name: "Gray"))
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        session.setPaletteColor(PaletteColor(red: 0, green: 0, blue: 1), background: true)
        session.addAdjustment(.gradientMap)
        let id = try #require(session.activeLayerID)
        let adjustment = try #require(session.activeLayer?.adjustment)
        #expect(adjustment.kind == .gradientMap)
        #expect(adjustment.gradientMap.shadows == AdjustmentColor(red: 1, green: 0, blue: 0))
        #expect(adjustment.gradientMap.highlights == AdjustmentColor(red: 0, green: 0, blue: 1))
        #expect(session.adjustmentEditingID == id)
        await session.beginAdjustmentEditing(id)
        #expect(session.filterEdit?.kind == .gradientMap, "edited in the floating filter panel, like Curves")
        session.finishAdjustmentEditing(commit: false)

        let rendered = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let middle = try pixels(rendered)[210]
        let mappedRed = middle[0], mappedGreen = middle[1], mappedBlue = middle[2]
        #expect(mappedRed > 100, "gray maps between red and blue: \(middle)")
        #expect(mappedBlue > 100, "\(middle)")
        #expect(mappedGreen < 20, "\(middle)")

        session.addAdjustment(.grain)
        let first = try #require(session.activeLayer?.adjustment?.grain.seed)
        session.adjustmentEditingID = nil // this test never opened its panel, so there is no edit to finish
        session.addAdjustment(.grain)
        #expect(session.document?.layers.filter { $0.adjustment?.kind == .grain }.count == 2)
        #expect(session.activeLayer?.adjustment?.grain.seed != first, "each Grain layer gets its own pattern")
        #expect(AdjustmentKind.allCases.contains(.exposure) && AdjustmentKind.exposure.filterKind == .exposure)
    }

    @Test func imageMenuExposureChangesTheLayerInOneStep() async throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        let base = try gray(width: 8, height: 8)
        session.insert(ImportedImage(image: base, thumbnail: base, name: "Gray"))
        session.beginFilter(.exposure)
        var settings = try #require(session.filterEdit).settings
        settings.exposure.exposure = 1
        session.updateFilter(settings, preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Exposure")
        let result = try pixels(try #require(session.activeLayer?.asset?.image))[0]
        #expect(abs(result[0] - 176) <= 2, "\(result)")
        #expect(FilterKind.exposure.isImageAdjustment && !FilterKind.gaussianBlur.isImageAdjustment)
    }

    /// Gradient Map's colors open the app's color picker: the gradient previews the working color,
    /// Cancel restores it, OK keeps it, and the palette is left alone.
    @Test func gradientMapColorsUseTheAppColorPicker() throws {
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        let base = try gray(width: 8, height: 8)
        session.insert(ImportedImage(image: base, thumbnail: base, name: "Gray"))
        let foreground = session.foregroundColor, background = session.backgroundColor
        session.beginFilter(.gradientMap)
        let edit = try #require(session.filterEdit)
        let start = edit.settings.gradientMap.highlights

        session.openGradientMapColorPicker(highlights: true)
        let picker = try #require(session.colorPicker)
        #expect(picker.target == .gradientMap(highlights: true))
        #expect(AdjustmentColor(picker.original) == start)
        picker.hsb.setRGB(PaletteColor(red: 1, green: 0, blue: 0))
        session.previewGradientMapColor()
        #expect(edit.settings.gradientMap.highlights == AdjustmentColor(red: 1, green: 0, blue: 0), "the gradient follows the working color")
        session.closeColorPicker(commit: false)
        #expect(edit.settings.gradientMap.highlights == start, "Cancel restores it")

        session.openGradientMapColorPicker(highlights: false)
        try #require(session.colorPicker).hsb.setRGB(PaletteColor(red: 0, green: 0, blue: 1))
        session.closeColorPicker(commit: true)
        #expect(edit.settings.gradientMap.shadows == AdjustmentColor(red: 0, green: 0, blue: 1))
        #expect(session.foregroundColor == foreground)
        #expect(session.backgroundColor == background, "the palette is untouched")

        session.openGradientMapColorPicker(highlights: true)
        session.cancelFilter()
        #expect(session.colorPicker == nil && session.filterEdit == nil, "closing the panel closes its picker")
    }
}
