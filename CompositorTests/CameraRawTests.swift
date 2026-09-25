import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawTests {
    private func image(width: Int = 4, height: Int = 4, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func gray(width: Int = 4, height: Int = 4, alpha: CGFloat = 1) throws -> CGImage {
        try image(width: width, height: height, red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: alpha)
    }

    /// Straight RGBA bytes, top row first.
    private func pixels(_ image: CGImage) throws -> [[Int]] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var result: [[Int]] = []
        for index in 0..<image.width * image.height {
            let alpha = Int(data[index * 4 + 3])
            var pixel: [Int] = []
            for channel in 0..<3 {
                let value: Int = alpha == 0 ? 0 : min(255, (Int(data[index * 4 + channel]) * 255 + alpha / 2) / alpha)
                pixel.append(value)
            }
            pixel.append(alpha)
            result.append(pixel)
        }
        return result
    }

    private func chroma(_ pixel: [Int]) -> Int {
        let rgb = [pixel[0], pixel[1], pixel[2]]
        return (rgb.max() ?? 0) - (rgb.min() ?? 0)
    }

    @Test func defaultsLeavePixelsAndAlphaAlone() throws {
        let input = try gray(alpha: 0.5)
        #expect(try pixels(CameraRawSettings().apply(input)) == pixels(input))
        var broken = CameraRawSettings()
        broken.exposure = .nan
        broken.temperature = 400
        #expect(!broken.isValid)
        #expect(broken.normalized.exposure == 0 && broken.normalized.temperature == 100)
        #expect(!FilterKind.cameraRaw.isImageAdjustment)
    }

    @Test func exposureAddsOneStopAndContrastPivotsAroundMidGray() throws {
        let input = try gray()
        var settings = CameraRawSettings()
        settings.exposure = 1
        let brighter = try pixels(settings.apply(input))[0]
        #expect(abs(brighter[0] - 176) <= 2, "+1 stop: \(brighter)")
        #expect(brighter[0] == brighter[1] && brighter[1] == brighter[2])
        let translucent = try gray(alpha: 0.5)
        #expect(try pixels(settings.apply(translucent))[0][3] == pixels(translucent)[0][3])

        let context = try BrushRaster.context(width: 2, height: 1, mask: false)
        context.setFillColor(CGColor(srgbRed: 64 / 255, green: 64 / 255, blue: 64 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(srgbRed: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let pair = try #require(context.makeImage())
        settings = CameraRawSettings()
        settings.contrast = 100
        let pushed = try pixels(settings.apply(pair))
        #expect(pushed[0][0] < 10 && pushed[1][0] > 250, "contrast +100 drives the pair apart: \(pushed)")
        settings.contrast = -100
        let flat = try pixels(settings.apply(pair))
        #expect(abs(flat[0][0] - 128) <= 2 && abs(flat[1][0] - 128) <= 2, "contrast −100 meets at mid gray: \(flat)")
    }

    @Test func tonalSlidersMoveTheEndTheyName() throws {
        let context = try BrushRaster.context(width: 2, height: 1, mask: false)
        context.setFillColor(CGColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let brightAndMid = try #require(context.makeImage())
        var settings = CameraRawSettings()
        settings.highlights = -100
        let recovered = try pixels(settings.apply(brightAndMid))
        #expect(recovered[0][0] < 200, "highlights −100 darkens the bright tone: \(recovered[0])")
        #expect(abs(recovered[1][0] - 128) <= 2, "and leaves mid gray: \(recovered[1])")

        settings = CameraRawSettings()
        settings.whites = 100
        let clipped = try pixels(settings.apply(brightAndMid))
        #expect(clipped[0][0] == 255, "whites +100 clips the bright tone: \(clipped[0])")
        #expect(abs(clipped[1][0] - 128) <= 2, "not the midtone: \(clipped[1])")
        let viz = try pixels(settings.apply(brightAndMid, clipping: .highlights))
        #expect(viz[0] == [255, 255, 255, 255] && viz[1] == [0, 0, 0, 255], "highlight clipping is not the grade: \(viz)")

        let darkContext = try BrushRaster.context(width: 2, height: 1, mask: false)
        darkContext.setFillColor(CGColor(srgbRed: 20 / 255, green: 20 / 255, blue: 20 / 255, alpha: 1))
        darkContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        darkContext.setFillColor(CGColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1))
        darkContext.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let darkAndMid = try #require(darkContext.makeImage())
        settings = CameraRawSettings()
        settings.shadows = 100
        let opened = try pixels(settings.apply(darkAndMid))
        #expect(opened[0][0] > 50, "shadows +100 opens the dark tone: \(opened[0])")
        #expect(abs(opened[1][0] - 128) <= 2, "and leaves mid gray: \(opened[1])")

        settings = CameraRawSettings()
        settings.blacks = -100
        let crushed = try pixels(settings.apply(darkAndMid))
        #expect(crushed[0][0] < 20, "blacks −100 crushes the dark tone: \(crushed[0])")
        #expect(abs(crushed[1][0] - 128) <= 2)
        let shadowViz = try pixels(settings.apply(darkAndMid, clipping: .shadows))
        #expect(shadowViz[0] == [0, 0, 0, 255] && shadowViz[1] == [255, 255, 255, 255], "shadow clipping is not the grade: \(shadowViz)")
    }

    @Test func temperatureWarmsAndTintMovesTowardMagenta() throws {
        let input = try gray()
        var settings = CameraRawSettings()
        settings.temperature = 100
        let warm = try pixels(settings.apply(input))[0]
        #expect(warm[0] > 128 && warm[2] < 128 && warm[0] > warm[2], "warm shifts red up and blue down: \(warm)")
        settings = CameraRawSettings()
        settings.tint = 100
        let magenta = try pixels(settings.apply(input))[0]
        #expect(magenta[1] < 128 && magenta[1] < magenta[0] && magenta[1] < magenta[2], "magenta lowers green: \(magenta)")
    }

    @Test func vibranceFavorsDullColorsAndProtectsSkinWhileSaturationDoesNot() throws {
        let dullGreen = try image(red: 77 / 255, green: 153 / 255, blue: 77 / 255)
        let saturatedGreen = try image(red: 20 / 255, green: 200 / 255, blue: 20 / 255)
        let skin = try image(red: 153 / 255, green: 115 / 255, blue: 77 / 255)
        var settings = CameraRawSettings()
        settings.vibrance = 100
        let dullBefore = try chroma(pixels(dullGreen)[0])
        let saturatedBefore = try chroma(pixels(saturatedGreen)[0])
        let skinBefore = try chroma(pixels(skin)[0])
        let dullDelta = try chroma(pixels(settings.apply(dullGreen))[0]) - dullBefore
        let saturatedDelta = try chroma(pixels(settings.apply(saturatedGreen))[0]) - saturatedBefore
        let skinDelta = try chroma(pixels(settings.apply(skin))[0]) - skinBefore
        #expect(dullDelta > saturatedDelta + 10, "dull \(dullDelta) vs saturated \(saturatedDelta)")
        #expect(dullBefore == skinBefore)
        #expect(dullDelta > skinDelta + 10, "skin is protected at the same saturation: \(skinDelta) vs \(dullDelta)")

        let red = try image(red: 160 / 255, green: 120 / 255, blue: 120 / 255)
        let blue = try image(red: 100 / 255, green: 100 / 255, blue: 140 / 255)
        settings = CameraRawSettings()
        settings.saturation = 100
        let redBefore = try chroma(pixels(red)[0])
        let blueBefore = try chroma(pixels(blue)[0])
        let redAfter = try chroma(pixels(settings.apply(red))[0])
        let blueAfter = try chroma(pixels(settings.apply(blue))[0])
        let redRatio = Double(redAfter) / Double(redBefore)
        let blueRatio = Double(blueAfter) / Double(blueBefore)
        #expect(abs(redRatio - 2) < 0.15 && abs(blueRatio - 2) < 0.15, "saturation doubles both: \(redRatio), \(blueRatio)")
    }

    @Test func eyedropperAndAutoNeutralizeAWarmPixel() throws {
        let straightRed = 160.0 / 255
        let straightGreen = 140.0 / 255
        let straightBlue = 120.0 / 255
        let warm = try image(width: 8, height: 8, red: straightRed, green: straightGreen, blue: straightBlue)
        let before = try pixels(warm)[0]
        let solved = try #require(CameraRawSettings.neutralize(straightRed: straightRed, green: straightGreen, blue: straightBlue))
        var settings = CameraRawSettings()
        settings.temperature = solved.temperature
        settings.tint = solved.tint
        let neutral = try pixels(settings.apply(warm))[0]
        #expect(chroma(neutral) < chroma(before) / 2, "eyedropper pulls the cast in: \(before) → \(neutral)")

        let auto = try #require(CameraRawSettings.autoBalance(of: warm))
        settings.temperature = auto.temperature
        settings.tint = auto.tint
        let averaged = try pixels(settings.apply(warm))[0]
        #expect(chroma(averaged) < chroma(before) / 2, "auto matches the solid color: \(averaged)")

        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: warm, thumbnail: warm, name: "Warm"))
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        edit.samplesWhiteBalance = true
        session.sampleCameraRawWhiteBalance(at: CGPoint(x: 1, y: 1))
        #expect(edit.settings.cameraRaw.whiteBalance == .custom)
        #expect(edit.settings.cameraRaw.temperature != 0 || edit.settings.cameraRaw.tint != 0)
        let sampled = try pixels(edit.renderSettings().cameraRaw.apply(warm))[0]
        #expect(chroma(sampled) < chroma(before) / 2, "the canvas sample neutralizes: \(sampled)")

        session.cancelFilter()
        let clear = try image(width: 8, height: 8, red: 1, green: 0, blue: 0, alpha: 0)
        let empty = EditorSession()
        empty.createDocument(width: 8, height: 8)
        empty.insert(ImportedImage(image: clear, thumbnail: clear, name: "Clear"))
        empty.beginFilter(.cameraRaw)
        let untouched = try #require(empty.filterEdit).settings
        empty.filterEdit?.samplesWhiteBalance = true
        empty.sampleCameraRawWhiteBalance(at: CGPoint(x: 1, y: 1))
        #expect(empty.filterEdit?.settings == untouched, "a transparent pixel is ignored")
    }

    /// Auto stores its mode, then fills Temperature and Tint from the layer once the scan finishes.
    @Test func autoWhiteBalanceNeutralizesAfterTheScan() async throws {
        let straightRed = 160.0 / 255
        let straightGreen = 140.0 / 255
        let straightBlue = 120.0 / 255
        let warm = try image(width: 8, height: 8, red: straightRed, green: straightGreen, blue: straightBlue)
        let before = try pixels(warm)[0]
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: warm, thumbnail: warm, name: "Warm"))
        session.beginFilter(.cameraRaw)
        await session.applyCameraRawAutoWhiteBalance()
        let raw = try #require(session.filterEdit).settings.cameraRaw
        #expect(raw.whiteBalance == .auto)
        let averaged = try pixels(raw.apply(warm))[0]
        #expect(chroma(averaged) < chroma(before) / 2, "auto neutralizes after the scan: \(averaged)")

        session.cancelFilter()
        let clear = try image(width: 8, height: 8, red: 1, green: 0, blue: 0, alpha: 0)
        let empty = EditorSession()
        empty.createDocument(width: 8, height: 8)
        empty.insert(ImportedImage(image: clear, thumbnail: clear, name: "Clear"))
        empty.beginFilter(.cameraRaw)
        await empty.applyCameraRawAutoWhiteBalance()
        let untouched = try #require(empty.filterEdit).settings.cameraRaw
        #expect(untouched.whiteBalance == .auto)
        #expect(untouched.temperature == 0 && untouched.tint == 0, "a layer with no coverage leaves the sliders alone")
    }

    @Test func hiddenGroupIsLeftOutAndOkIsOneUndoOrNone() async throws {
        let input = try gray(width: 8, height: 8)
        var settings = CameraRawSettings()
        settings.exposure = 1
        settings.temperature = 40
        let hiddenLight = settings.applying(showsLight: false, showsColor: true)
        let colorOnly = try pixels(hiddenLight.apply(input))
        let source = try pixels(input)
        #expect(colorOnly != source)
        #expect(hiddenLight.exposure == 0 && hiddenLight.temperature == 40)
        let neither = settings.applying(showsLight: false, showsColor: false)
        #expect(neither.isIdentity)
        #expect(try pixels(neither.apply(input)) == source)

        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: input, thumbnail: input, name: "Gray"))
        session.beginFilter(.cameraRaw)
        let original = try pixels(input)
        var count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count, "an unchanged grade is not an edit")
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == original)

        session.beginFilter(.cameraRaw)
        var editSettings = try #require(session.filterEdit).settings
        editSettings.cameraRaw.exposure = 1
        session.updateFilter(editSettings, preview: true)
        session.filterEdit?.showsCameraRawLight = false
        count = session.history.undoCount
        await session.commitFilter()
        #expect(session.history.undoCount == count, "an eye turned off drops that group")
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == original)

        session.beginFilter(.cameraRaw)
        editSettings = try #require(session.filterEdit).settings
        editSettings.cameraRaw.exposure = 1
        session.updateFilter(editSettings, preview: true)
        session.cancelFilter()
        #expect(session.filterEdit == nil)
        #expect(try pixels(try #require(session.activeLayer?.asset?.image)) == original)

        session.beginFilter(.cameraRaw)
        editSettings = try #require(session.filterEdit).settings
        editSettings.cameraRaw.exposure = 1
        session.updateFilter(editSettings, preview: true)
        count = session.history.undoCount
        await session.commitFilter()
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Camera Raw Filter")
        let baked = try pixels(try #require(session.activeLayer?.asset?.image))[0]
        #expect(abs(baked[0] - 176) <= 2, "OK bakes the grade: \(baked)")
    }

    /// OK stores the grade the eye left in the layer. A hidden slider must not come back on the next open.
    @Test func hiddenGroupStaysOutOfTheNextOpen() async throws {
        let input = try gray(width: 8, height: 8)
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: input, thumbnail: input, name: "Gray"))
        session.beginFilter(.cameraRaw)
        var editSettings = try #require(session.filterEdit).settings
        editSettings.cameraRaw.exposure = 1
        editSettings.cameraRaw.temperature = 40
        session.updateFilter(editSettings, preview: true)
        session.filterEdit?.showsCameraRawLight = false
        await session.commitFilter()
        let baked = try pixels(try #require(session.activeLayer?.asset?.image))
        let source = try pixels(input)
        #expect(baked != source)

        session.beginFilter(.cameraRaw)
        let restored = try #require(session.filterEdit).settings.cameraRaw
        #expect(restored.exposure == 0)
        #expect(restored.temperature == 40)
        session.cancelFilter()
    }

    /// A wide step from 40 to 200, so a small blur and a wide blur reach different pixels.
    /// A checkerboard, for the geometry and optics tests: a warp moves pixels, so it can only be seen
    /// in an image whose pixels differ. A flat fill comes back byte-identical however hard it is bent.
    private func checker(_ width: Int = 24, _ height: Int = 24) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        for y in 0..<height {
            for x in 0..<width {
                let light = ((x / 2) + (y / 2)) % 2 == 0
                context.setFillColor(CGColor(srgbRed: light ? 0.9 : 0.1, green: light ? 0.9 : 0.1,
                                             blue: light ? 0.9 : 0.1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    private func step() throws -> CGImage {
        let width = 24
        let context = try BrushRaster.context(width: width, height: 4, mask: false)
        context.setFillColor(CGColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 4))
        context.setFillColor(CGColor(srgbRed: 200 / 255, green: 200 / 255, blue: 200 / 255, alpha: 1))
        context.fill(CGRect(x: 12, y: 0, width: 12, height: 4))
        return try #require(context.makeImage())
    }

    private func byte(_ image: CGImage, x: Int) throws -> Int {
        try pixels(image)[x][0]
    }

    @Test func textureAndClaritySharpenAnEdgeAndLeaveAFlatField() throws {
        let flat = try gray()
        let flatPixels = try pixels(flat)
        var settings = CameraRawSettings()
        settings.texture = 100
        settings.clarity = 100
        let flatResult = try pixels(settings.apply(flat))
        #expect(flatResult == flatPixels, "a flat field has no local contrast")

        let edge = try step()
        let originalFar = try byte(edge, x: 0)
        let originalNear = try byte(edge, x: 8)
        let originalEdge = try byte(edge, x: 11)
        settings = CameraRawSettings()
        settings.texture = 100
        let textured = try settings.apply(edge)
        #expect(try byte(textured, x: 0) == originalFar)
        #expect(try byte(textured, x: 8) == originalNear, "texture's fine radius does not reach this far")
        #expect(try byte(textured, x: 11) != originalEdge)

        settings = CameraRawSettings()
        settings.clarity = 100
        let clarified = try settings.apply(edge)
        #expect(try byte(clarified, x: 0) == originalFar)
        #expect(try byte(clarified, x: 8) != originalNear, "clarity's wider radius reaches further in")
        settings.clarity = -100
        let softened = try settings.apply(edge)
        let hardBright = try byte(edge, x: 12)
        let hardDark = try byte(edge, x: 11)
        let softBright = try byte(softened, x: 12)
        let softDark = try byte(softened, x: 11)
        let hardGap = abs(hardBright - hardDark)
        let softGap = abs(softBright - softDark)
        #expect(softGap < hardGap, "negative clarity pulls the step together: \(softGap) vs \(hardGap)")
    }

    @Test func dehazeDeepensOrLiftsAndKeepsAlpha() throws {
        let dark = try image(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
        let pale = try image(red: 180 / 255, green: 150 / 255, blue: 150 / 255)
        var settings = CameraRawSettings()
        settings.dehaze = 100
        let deepened = try pixels(settings.apply(dark))[0]
        #expect(deepened[0] < 30, "positive dehaze darkens a shadow: \(deepened)")
        let paleBefore = try pixels(pale)[0]
        let paleAfter = try pixels(settings.apply(pale))[0]
        #expect(chroma(paleAfter) > chroma(paleBefore), "and raises saturation: \(paleBefore) → \(paleAfter)")
        settings.dehaze = -100
        let lifted = try pixels(settings.apply(dark))[0]
        #expect(lifted[0] > 30, "negative dehaze lifts a shadow: \(lifted)")
        let faded = try pixels(settings.apply(pale))[0]
        #expect(chroma(faded) < chroma(paleBefore), "and lowers saturation: \(faded)")
        let translucent = try image(red: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 0.5)
        let translucentAlpha = try pixels(translucent)[0][3]
        settings.dehaze = 100
        let dehazedAlpha = try pixels(settings.apply(translucent))[0][3]
        #expect(dehazedAlpha == translucentAlpha)
    }

    @Test func glowIsIdleAtZeroAndHalationFringeIsRedderThanDiffusion() throws {
        let context = try BrushRaster.context(width: 21, height: 21, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 21, height: 21))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: 5, height: 5))
        let spot = try #require(context.makeImage())
        let spotPixels = try pixels(spot)
        var settings = CameraRawSettings()
        settings.glowWarmth = 100
        settings.glowRange = 100
        let idle = try pixels(settings.apply(spot))
        #expect(idle == spotPixels, "range and warmth do nothing until Glow is raised")

        settings.glow = 100
        settings.glowWarmth = 100
        settings.glowStyle = .diffusion
        let diffusion = try pixels(settings.apply(spot))
        settings.glowStyle = .halation
        let halation = try pixels(settings.apply(spot))
        let fringe = 10 * 21 + 15
        let far = 0
        #expect(diffusion[fringe][0] > diffusion[far][0], "glow brightens the neighborhood: \(diffusion[fringe])")
        #expect(halation[far] == [0, 0, 0, 255])
        let diffusionRed = diffusion[fringe][0] - diffusion[fringe][1]
        let halationRed = halation[fringe][0] - halation[fringe][1]
        #expect(halationRed > diffusionRed, "halation is redder than diffusion at the same warmth: \(halation[fringe]) vs \(diffusion[fringe])")
    }

    @Test func vignetteDarkensCornersAndHighlightsOnlyWhileDarkening() throws {
        let grayField = try gray(width: 9, height: 9)
        var settings = CameraRawSettings()
        settings.vignetteAmount = -100
        let darkened = try pixels(settings.apply(grayField))
        let center = darkened[4 * 9 + 4][0]
        let corner = darkened[0][0]
        #expect(abs(center - 128) <= 2, "the center stays: \(center)")
        #expect(corner < center - 40, "the corner darkens: \(corner)")

        let white = try image(width: 9, height: 9, red: 1, green: 1, blue: 1)
        settings.vignetteHighlights = 100
        settings.vignetteStyle = .highlightPriority
        let protected = try pixels(settings.apply(white))[0][0]
        settings.vignetteHighlights = 0
        let exposed = try pixels(settings.apply(white))[0][0]
        #expect(protected > exposed + 40, "highlights holds a bright corner: \(protected) vs \(exposed)")
        settings.vignetteHighlights = 100
        settings.vignetteStyle = .paintOverlay
        let painted = try pixels(settings.apply(white))[0][0]
        #expect(painted < protected, "paint overlay does not use Highlights: \(painted)")

        settings = CameraRawSettings()
        settings.vignetteAmount = 100
        settings.vignetteHighlights = 0
        let plain = try pixels(settings.apply(grayField))
        settings.vignetteHighlights = 100
        let withHighlights = try pixels(settings.apply(grayField))
        #expect(plain == withHighlights, "highlights is idle while the vignette lightens")
    }

    @Test func grainIsStableAndTheEffectsEyeDropsTheWholeGroup() throws {
        let field = try gray(width: 16, height: 16)
        let fieldPixels = try pixels(field)
        var settings = CameraRawSettings()
        settings.grainSize = 40
        settings.grainRoughness = 80
        let silent = try pixels(settings.apply(field, seed: 4))
        #expect(silent == fieldPixels, "size and roughness do nothing at amount zero")
        settings.grainAmount = 70
        let first = try pixels(settings.apply(field, seed: 4))
        let second = try pixels(settings.apply(field, seed: 4))
        #expect(first == second, "the same seed keeps the same grain")
        #expect(first != fieldPixels)
        #expect(first[0][0] == first[0][1] && first[0][1] == first[0][2], "grain moves brightness only")
        let clear = try image(width: 4, height: 4, red: 0.5, green: 0.5, blue: 0.5, alpha: 0)
        let clearPixels = try pixels(settings.apply(clear, seed: 4))
        #expect(clearPixels[0][3] == 0)

        let edge = try step()
        let edgePixels = try pixels(edge)
        settings = CameraRawSettings()
        settings.texture = 100
        settings.grainAmount = 50
        let shown = try pixels(settings.apply(edge, seed: 2))
        let hidden = settings.applying(showsLight: true, showsColor: true, showsEffects: false)
        let hiddenPixels = try pixels(hidden.apply(edge, seed: 2))
        #expect(hidden.isIdentity)
        #expect(hiddenPixels == edgePixels)
        #expect(shown != edgePixels)
    }

    @Test func histogramFollowsTheGradeAndClippingPaintStaysOffTheResult() throws {
        let black = try image(red: 0, green: 0, blue: 0)
        let white = try image(red: 1, green: 1, blue: 1)
        let blackScope = try #require(CameraRawScope.make(black))
        let whiteScope = try #require(CameraRawScope.make(white))
        #expect(peakIndex(blackScope.red) == 0)
        #expect(peakIndex(whiteScope.red) == 255)
        var settings = CameraRawSettings()
        settings.exposure = 1
        let shifted = try #require(CameraRawScope.make(settings.apply(try gray())))
        #expect(peakIndex(shifted.red) > 128, "exposure moves the midtones toward white")

        let shadowed = try pixels(CameraRawScope.overlay(black, shadows: true, highlights: false))[0]
        #expect(shadowed[2] > shadowed[0], "clipped shadows are painted blue: \(shadowed)")
        let highlighted = try pixels(CameraRawScope.overlay(white, shadows: false, highlights: true))[0]
        #expect(highlighted[0] > highlighted[2], "clipped highlights are painted red: \(highlighted)")
        let untouched = try pixels(CameraRawScope.overlay(black, shadows: false, highlights: false))
        let originalBlack = try pixels(black)
        #expect(untouched == originalBlack)

        let red = try image(red: 1, green: 0, blue: 0)
        let scope = try #require(CameraRawScope.make(red))
        let hottest = scope.vectorscope.enumerated().max { $0.element < $1.element }?.offset ?? 0
        #expect(hottest % CameraRawScope.scopeSide > CameraRawScope.scopeSide / 2, "red sits on the right of the vectorscope")
    }

    @Test func curveMixerAndGradingChangeOnlyTheirOwnTones() throws {
        let dark = try image(red: 0.12, green: 0.12, blue: 0.12)
        let light = try image(red: 0.62, green: 0.62, blue: 0.62)
        var settings = CameraRawSettings()
        settings.curve.shadows = 100
        let darkGain = try pixels(settings.apply(dark))[0][0] - Int((0.12 * 255).rounded())
        let lightGain = try pixels(settings.apply(light))[0][0] - Int((0.62 * 255).rounded())
        #expect(darkGain > lightGain + 8, "parametric shadows lift the dark tone more: \(darkGain) vs \(lightGain)")

        settings = CameraRawSettings()
        settings.curve.rgb = CameraRawCurveSettings.strongContrast
        let contrasted = try pixels(settings.apply(image(red: 0.25, green: 0.25, blue: 0.25)))[0][0]
        #expect(contrasted < 55, "strong contrast pulls a dark midtone down: \(contrasted)")

        settings = CameraRawSettings()
        settings.mixer.hue[0] = 100
        let shifted = try pixels(settings.apply(image(red: 1, green: 0, blue: 0)))[0]
        #expect(shifted[1] > shifted[2], "reds hue moves red toward orange: \(shifted)")

        settings = CameraRawSettings()
        settings.grading.shadows.saturation = 100
        let gradedDark = try pixels(settings.apply(dark))[0]
        let gradedLight = try pixels(settings.apply(image(red: 1, green: 1, blue: 1)))[0]
        #expect(gradedDark[0] > gradedDark[1] + 5, "shadow grading tints a dark pixel: \(gradedDark)")
        #expect(abs(gradedLight[0] - gradedLight[1]) <= 2, "and leaves white alone: \(gradedLight)")
        settings.grading.balance = 100
        let balanced = try pixels(settings.apply(dark))[0]
        #expect(balanced[0] - balanced[1] < gradedDark[0] - gradedDark[1], "balance toward highlights weakens the shadow tint")

        settings = CameraRawSettings()
        settings.curve.shadows = 100
        let hidden = settings.applying(showsLight: true, showsColor: true, showsCurve: false)
        #expect(try pixels(hidden.apply(dark)) == pixels(dark))
    }

    @Test func detailSharpeningNoiseAndMaskingPreview() throws {
        let edge = try step()
        var settings = CameraRawSettings()
        settings.detail.sharpenAmount = 150
        settings.detail.sharpenRadius = 50
        let sharpened = try settings.apply(edge)
        let before = try pixels(edge)
        let after = try pixels(sharpened)
        #expect(before != after, "sharpening changes the step image")

        settings = CameraRawSettings()
        settings.detail.noiseLuminance = 80
        let flat = try gray(width: 8, height: 8)
        let smoothedFlat = try pixels(settings.apply(flat))
        let flatPixels = try pixels(flat)
        #expect(smoothedFlat == flatPixels, "luminance NR leaves a flat field alone")

        settings.detail.sharpenMasking = 50
        let mask = try settings.apply(edge, sharpenMask: true)
        let maskPixels = try pixels(mask)
        #expect(maskPixels.allSatisfy { $0[0] == $0[1] && $0[1] == $0[2] }, "mask preview is grayscale")
        #expect(settings.detail.adjusts)
    }

    @Test func opticsDistortionDefringeAndDetailEye() throws {
        let stepped = try checker()
        var settings = CameraRawSettings()
        settings.optics.distortion = 100
        let warped = try settings.apply(stepped)
        let warpedPixels = try pixels(warped)
        let steppedPixels = try pixels(stepped)
        // Not the step image: its one edge sits at the centre, where a radial distortion moves nothing.
        #expect(warpedPixels != steppedPixels, "distortion resamples pixels")

        let purple = try image(red: 0.8, green: 0.2, blue: 0.9)
        let purpleBefore = try pixels(purple)[0]
        settings = CameraRawSettings()
        settings.optics.purpleAmount = 100
        settings.optics.purpleHueLow = 250
        settings.optics.purpleHueHigh = 320
        let defringed = try pixels(settings.apply(purple))[0]
        #expect(chroma(defringed) < chroma(purpleBefore), "purple defringe lowers chroma")

        settings = CameraRawSettings()
        settings.optics.removeChromaticAberration = true
        #expect(settings.optics.adjusts)
        settings = CameraRawSettings()
        settings.detail.sharpenAmount = 40
        let hidden = settings.applying(showsLight: true, showsColor: true, showsDetail: false)
        let edgeImage = try step()
        let original = try pixels(edgeImage)
        let preview = try pixels(hidden.apply(edgeImage))
        #expect(preview == original)
    }

    @Test func geometryWarpAndCalibrationPrimaries() throws {
        let grid = try checker(12, 12)
        var settings = CameraRawSettings()
        settings.geometry.vertical = 40
        let warped = try settings.geometry.apply(grid)
        let warpedPixels = try pixels(warped)
        let gridPixels = try pixels(grid)
        #expect(warpedPixels != gridPixels)

        settings = CameraRawSettings()
        settings.calibration.redHue = 80
        let red = try image(red: 1, green: 0, blue: 0)
        let before = try pixels(red)[0]
        let after = try pixels(settings.apply(red))[0]
        #expect(after != before, "calibration shifts a pure red: \(before) → \(after)")

        settings.calibration.redHue = 80
        let hidden = settings.applying(showsLight: true, showsColor: true, showsCalibration: false)
        let hiddenPixels = try pixels(hidden.apply(red))
        #expect(hiddenPixels[0] == before)
    }

    /// Upright is Off or Guided. Guided reads a drawn line; without one it must not invent a warp,
    /// and two different pictures must not receive one shared result.
    @Test func guidedUprightFollowsADrawnLineAndLeavesAnUnguidedPicture() throws {
        #expect(Set(CameraRawUprightMode.allCases) == [.off, .guided])
        let cool = try image(width: 16, height: 16, red: 0.2, green: 0.45, blue: 0.8)
        let warm = try image(width: 16, height: 16, red: 0.85, green: 0.25, blue: 0.15)
        let coolPixels = try pixels(cool)
        let warmPixels = try pixels(warm)
        var settings = CameraRawSettings()
        settings.geometry.upright = .guided
        #expect(try pixels(settings.apply(cool)) == coolPixels)
        #expect(try pixels(settings.apply(warm)) == warmPixels)

        settings.geometry.guides = [CameraRawGeometryGuide(startX: 0.1, startY: 0.15, endX: 0.9, endY: 0.8)]
        let coolGuided = try pixels(settings.apply(cool))
        let warmGuided = try pixels(settings.apply(warm))
        #expect(coolGuided != coolPixels)
        #expect(warmGuided != warmPixels)
        #expect(coolGuided != warmGuided)
    }

    private func peakIndex(_ bins: [Double]) -> Int {
        bins.enumerated().max { $0.element < $1.element }?.offset ?? -1
    }
}
