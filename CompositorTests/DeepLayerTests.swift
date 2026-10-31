import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Compositor

/// 16-bit layers in 8-bit documents (`DeepLayer`): imported 16-bit images keep their precision through Levels,
/// filters, saving and 16-bit export, while every tool keeps working on their dithered 8-bit copy.
@MainActor
struct DeepLayerTests {
    static let width = 256, height = 8

    /// A 16-bit PNG of a gray ramp four 8-bit steps wide (100 to 104), so it holds about 256 distinct 16-bit values
    /// but only five 8-bit ones.
    private func ramp16() throws -> URL {
        let context = try DeepLayer.context(width: Self.width, height: Self.height)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let value = UInt16(((100 + 4 * Double(x) / Double(Self.width - 1)) / 255 * 65535).rounded())
                let i = (y * Self.width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 65535
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The red channel of a row, at 16 bits.
    private func row(_ image: CGImage, _ y: Int = 4) throws -> [Int] {
        let context = try DeepLayer.canonical(image)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        return (0..<image.width).map { Int(pixels[(y * image.width + $0) * 4]) }
    }

    private func importedSession() async throws -> (EditorSession, URL) {
        let url = try ramp16()
        let session = EditorSession()
        await session.importImages([url])
        return (session, url)
    }

    @Test func sixteenBitImportsBecomeSixteenBitLayers() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try #require(session.activeLayer?.asset)
        let deep = try #require(asset.deep, "the layer keeps its 16-bit pixels")
        #expect(deep.bitsPerComponent == 16 && asset.image.bitsPerComponent == 8)
        #expect(Set(try row(deep)).count > 200, "the ramp's fine steps are all there")
        #expect(session.activeLayer?.depthLabel == "16-Bit")
    }

    /// Levels stretching the ramp's four steps across the whole range: the 16-bit layer comes out a smooth ramp,
    /// where 8 bits could only make five flat bands of it.
    @Test func levelsKeepsSixteenBitPrecision() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginLevels()
        var settings = LevelsSettings()
        settings.ranges[0].black = 100
        settings.ranges[0].white = 104
        session.updateLevels(settings, preview: true)
        await session.commitLevels()
        let deep = try #require(session.activeLayer?.asset?.deep, "Levels kept the layer 16-bit")
        let values = try row(deep)
        #expect(Set(values).count > 150, "a smooth ramp, not bands: \(Set(values).count) distinct values")
        // Ideally 0 at the left, 65535 at the right, straight between; allow a couple of 8-bit steps either way.
        let worst = values.enumerated().map { abs(Double($1) - Double($0) / Double(Self.width - 1) * 65535) }.max() ?? 0
        #expect(worst < 3 * 257, "follows the stretched ramp: worst \(worst / 257) steps off")
    }

    /// Levels halving the output range: each 8-bit step moves the result by only half a step, so read one step
    /// apart, runs of the ramp would come out flat. Read four apart (`deep_merge`), it stays a fine ramp. Within half a
    /// step of exact, not closer: the 8-bit operation rounds its own results, which the 16-bit one is read off.
    @Test func compressingToneChangesStaySmooth() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginLevels()
        var settings = LevelsSettings()
        settings.ranges[0].outputWhite = 127.5
        session.updateLevels(settings, preview: true)
        await session.commitLevels()
        let values = try row(try #require(session.activeLayer?.asset?.deep))
        #expect(Set(values).count > 200, "\(Set(values).count) distinct values")
        var worst = 0.0
        for (x, value) in values.enumerated() {
            let level = 100 + 4 * Double(x) / Double(Self.width - 1)
            let exact = level / 2 / 255 * 65535
            worst = max(worst, abs(Double(value) - exact))
        }
        #expect(worst < 257 * 0.6, "within half a step of exact: \(worst / 257) steps off")
    }

    @Test func filtersKeepSixteenBitPixels() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 2), preview: true)
        await session.commitFilter()
        let asset = try #require(session.activeLayer?.asset)
        let deep = try #require(asset.deep, "the blurred layer is still 16-bit")
        #expect(deep.width == asset.image.width && deep.height == asset.image.height)
        // Run once in Core Image at 16 bits: a blurred straight ramp is the same ramp, away from its ends.
        let values = try row(deep)
        var worst = 0.0
        for x in 16..<(Self.width - 16) {
            let ideal = (100 + 4 * Double(x) / Double(Self.width - 1)) / 255 * 65535
            worst = max(worst, abs(Double(values[x]) - ideal))
        }
        #expect(worst < 26, "within a tenth of an 8-bit step: worst \(worst / 257) steps off")
    }

    @Test func savingAndReopeningKeepsTheSixteenBitPixels() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try #require(session.activeLayer?.id)
        let before = try #require(session.activeLayer?.asset?.deep)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: project) }
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        try await ProjectStore.shared.save(snapshot, to: project)
        let loaded = try await ProjectStore.shared.load(from: project)
        let after = try #require(loaded.images[id]?.deep, "reopened as a 16-bit layer")
        #expect(try row(after) == row(before), "pixel for pixel")
    }

    @Test func sixteenBitExportKeepsThePrecision() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        let deep = try await ImageExporter.shared.render(snapshot, sixteenBit: true).image
        #expect(deep.bitsPerComponent == 16)
        #expect(Set(try row(deep)).count > 200)
        let flat = try await ImageExporter.shared.render(snapshot).image
        #expect(flat.bitsPerComponent == 8, "an ordinary export is unchanged")
    }

    @Test func hueSaturationKeepsSixteenBitPixels() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = HueSaturationSettings()
        settings.adjustments[.master] = RangeAdjustment(hue: 0, saturation: 0, lightness: 20)
        session.beginHueSaturation()
        session.updateHueSaturation(settings, preview: true)
        await session.hueSaturationTask?.value
        await session.commitHueSaturation()
        let deep = try #require(session.activeLayer?.asset?.deep, "Hue/Saturation kept the layer 16-bit")
        #expect(Set(try row(deep)).count > 200, "still a fine ramp")
    }

    @Test func imageSizeResamplesAtSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: Self.width * 2, height: Self.height * 2, resolution: 72))
        session.applyImageSize(result)
        let deep = try #require(session.activeLayer?.asset?.deep, "the resized layer is still 16-bit")
        #expect(deep.width == Self.width * 2 && deep.bitsPerComponent == 16)
        #expect(Set(try row(deep, 8)).count > 300, "the doubled ramp has finer steps, not copied 8-bit ones")
    }

    /// Flip, crop and rotating the canvas change only the layer's transform: its 16-bit pixels are untouched.
    @Test func flippingAndRotatingKeepSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.flipCanvas(horizontally: true)
        session.rotateCanvas(clockwise: true)
        #expect(session.activeLayer?.asset?.deep != nil)
    }

    /// Painting lays its strokes over the 16-bit pixels as 8-bit patches: the layer stays 16-bit, the unpainted part
    /// keeps every fine step, and saving writes the whole of it at 16 bits.
    @Test func paintingKeepsTheRestSixteenBit() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try #require(session.activeLayer?.id)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 1, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 10, y: 4))
        session.continueBrush(at: CGPoint(x: 20, y: 4))
        await session.finishBrush()
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.raster != nil && asset.deep != nil, "painted, and still 16-bit")
        #expect(session.activeLayer?.depthLabel == "16-Bit")
        let whole = try #require(try DeepLayer.flattened(asset))
        let values = try row(whole)
        #expect(values[15] > values[200], "the stroke is in: red painted at the left")
        #expect(Set(values[64...]).count > 150, "and the rest keeps its fine steps")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: project) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: project)
        let reopened = try #require(try await ProjectStore.shared.load(from: project).images[id]?.deep)
        #expect(try row(reopened) == values, "saved whole, at 16 bits")
    }

    @Test func invertKeepsSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try row(try #require(session.activeLayer?.asset?.deep))
        await session.invertPixels()
        let after = try row(try #require(session.activeLayer?.asset?.deep, "Invert kept the layer 16-bit"))
        #expect(Set(after).count > 200)
        #expect(abs(after[128] - (65535 - before[128])) < 257, "inverted: \(after[128]) from \(before[128])")
    }

    /// Delete inside a selection (like Fill, Gradient and Move Pixels) commits through `BrushCommit`: the layer stays
    /// 16-bit and the rest keeps its steps.
    @Test func clearingASelectionKeepsSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 32, height: Self.height), transform: nil),
                                               antialiased: false, feather: 0), name: "Left")
        await session.clearSelectedPixels()
        let whole = try #require(try session.activeLayer?.asset.flatMap { try DeepLayer.flattened($0) })
        let values = try row(whole)
        #expect(whole.width == Self.width - 32, "the cleared edge is trimmed away")
        #expect(Set(values).count > 150, "the rest keeps its fine steps")
    }

    /// Cmd-T on a selection lifts it into a floating layer and drops it back: both stay 16-bit.
    @Test func floatingSelectionsKeepSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(session.activeLayer?.id)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 64, y: 0, width: 128, height: Self.height), transform: nil),
                                               antialiased: false, feather: 0), name: "Middle")
        await session.beginSelectionTransform()
        #expect(session.activeLayer?.asset?.deep != nil, "the floating selection is 16-bit")
        session.commitTransform()
        let layer = try #require(session.document?.layers.first { $0.id == source })
        let whole = try #require(try layer.asset.flatMap { try DeepLayer.flattened($0) }, "dropped back into a 16-bit layer")
        #expect(Set(try row(whole)[64..<192]).count > 100, "the moved pixels kept their fine steps")
    }

    @Test func mergingKeepsSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 4, hardness: 1, red: 1, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 10, y: 4))
        session.continueBrush(at: CGPoint(x: 14, y: 4))
        await session.finishBrush()
        session.mergeLayers()
        #expect(session.document?.layers.count == 1)
        let deep = try #require(session.activeLayer?.asset?.deep, "the merged layer is 16-bit")
        #expect(Set(try row(deep)[64...]).count > 150, "and keeps the 16-bit layer's fine steps")
    }

    @Test func distortKeepsSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.selectTool(.move)
        session.beginTransform(persistent: false)
        session.beginDistort()
        let w = CGFloat(Self.width), h = CGFloat(Self.height)
        session.previewCorners([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w - 20, y: h), CGPoint(x: 20, y: h)])
        session.commitTransform()
        let deep = try #require(session.activeLayer?.asset?.deep, "the distorted layer is 16-bit")
        #expect(Set(try row(deep, 0)).count > 150)
    }

    /// The share of a row's pixels between `from` and `to` holding values 8 bits can't (not a multiple of 257).
    private func fineShare(_ values: [Int], _ from: Int, _ to: Int) -> Double {
        let part = values[from..<to]
        return Double(part.filter { $0 % 257 != 0 }.count) / Double(part.count)
    }

    /// Liquify, Smudge and the Blur tool paint at 16 bits into a 16-bit layer, so where they go stays smooth: at 8 bits
    /// every pixel they touched would be a whole 8-bit step (and a smooth ramp would band).
    @Test(arguments: [BlurToolMode.liquify, .smudge, .blur])
    func blurToolModesKeepSixteenBits(mode: BlurToolMode) async throws {
        guard GPUCanvasRenderer.shared != nil || mode == .blur else { return }
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.selectTool(.blur)
        session.blurMode = mode
        session.brushSettings = BrushSettings(diameter: 8, hardness: 0.5, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 80, y: 4))
        for x in stride(from: 84.0, through: 170, by: 4) { session.continueBrush(at: CGPoint(x: x, y: 4)) }
        await session.finishBrush()
        let asset = try #require(session.activeLayer?.asset)
        let deep = try #require(try DeepLayer.flattened(asset), "\(mode) kept the layer 16-bit")
        let share = fineShare(try row(deep), 90, 160)
        #expect(share > 0.8, "\(mode): \(Int(share * 100))% of the stroke's pixels finer than 8 bits")
    }

    /// Dither works at 8 bits (its result is a few levels by design), but the layer stays 16-bit: where it dithered, its
    /// 8-bit values are taken; outside its selection the 16-bit pixels are kept exactly. Convert to 8-Bit alone makes a
    /// layer 8-bit.
    @Test func eightBitFiltersKeepTheLayerSixteenBit() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try row(try #require(session.activeLayer?.asset?.deep))
        session.selectTool(.marquee)
        session.beginLasso(at: .zero, mode: .replace)
        session.dragMarquee(to: CGPoint(x: Self.width / 2, y: Self.height), square: false, fromCenter: false)
        session.finishLasso()
        session.beginFilter(.dither)
        session.updateFilter(FilterSettings(), preview: true)
        await session.commitFilter()
        let deep = try #require(session.activeLayer?.asset?.deep, "still 16-bit")
        let after = try row(deep)
        #expect(after[(Self.width / 2)...] == before[(Self.width / 2)...], "untouched pixels keep their 16 bits")
        #expect(after[..<(Self.width / 2)].allSatisfy { $0 % 257 == 0 }, "dithered pixels are its 8-bit values")
        session.convertLayers(toSixteenBit: false)
        #expect(session.activeLayer?.asset?.deep == nil, "Convert to 8-Bit still makes it 8-bit")
    }

    /// An adjustment layer over a 16-bit layer, on its own or clipped to it, works at 16 bits in a 16-bit export: a
    /// steep Levels comes out a smooth ramp, not bands.
    @Test(arguments: [false, true])
    func adjustmentLayersExportAtSixteenBits(clipped: Bool) async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.addAdjustment(.levels)
        let id = try #require(session.activeLayerID)
        var adjustment = try #require(session.activeLayer?.adjustment)
        adjustment.levels.ranges[0].black = 100
        adjustment.levels.ranges[0].white = 104
        session.updateAdjustment(id, value: adjustment)
        session.adjustmentEditingID = nil
        if clipped { session.toggleClippingMask(id) }
        #expect((session.activeLayer?.maskSourceID != nil) == clipped)
        let snapshot = try #require(session.projectSnapshot())
        let values = try row(try await ImageExporter.shared.render(snapshot, sixteenBit: true).image)
        #expect(Set(values).count > 150, "\(Set(values).count) distinct values")
        #expect(values.first! < 3 * 257 && values.last! > 65535 - 3 * 257)
    }

    /// A channel averaged down the rows and over 9 pixels along them, in 8-bit steps: what's left once fine noise is
    /// averaged out.
    private func averaged(_ image: CGImage, channel: Int) throws -> [Double] {
        let context = try DeepLayer.canonical(image)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        let width = image.width, height = image.height
        var columns = [Double](repeating: 0, count: width)
        for x in 0..<width {
            for y in 0..<height { columns[x] += Double(pixels[(y * width + x) * 4 + channel]) / Double(height) / 257 }
        }
        var smoothed: [Double] = []
        for x in 8..<(width - 8) { smoothed.append(columns[(x - 4)...(x + 4)].reduce(0, +) / 9) }
        return smoothed
    }

    /// The sharpest bend along a channel once fine noise is averaged out: how much its rise over 12 pixels changes from
    /// one 12 to the next, in 8-bit steps. A smooth ramp barely bends; a band's edge does.
    private func bends(_ image: CGImage, channel: Int) throws -> Double {
        let values = try averaged(image, channel: channel)
        var worst = 0.0
        for x in 12..<(values.count - 12) {
            worst = max(worst, abs((values[x + 12] - values[x]) - (values[x] - values[x - 12])))
        }
        return worst
    }

    /// What an 8-bit operation makes of a 16-bit image, near exactly: its results on many randomly dithered 8-bit copies,
    /// averaged.
    private func reference(_ deep: CGImage, through operation: (CGImage) throws -> CGImage) throws -> CGImage {
        let width = deep.width, height = deep.height, copies = 64
        let source = try DeepLayer.canonical(deep)
        let input = try #require(source.data).assumingMemoryBound(to: UInt16.self)
        var sum = [Double](repeating: 0, count: width * height * 4)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<copies {
            let copy = try BrushRaster.context(width: width, height: height, mask: false)
            let bytes = try #require(copy.data).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * height * 4) {
                let value = Double(input[i]) / 257 + Double.random(in: 0..<1, using: &generator)
                bytes[i] = UInt8(min(255, value.rounded(.down)))
            }
            let result = try BrushRaster.copy(try operation(try #require(copy.makeImage())))
            let out = try #require(result.data).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(width * height * 4) { sum[i] += Double(out[i]) / Double(copies) }
        }
        let context = try DeepLayer.context(width: width, height: height)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for i in 0..<(width * height * 4) { pixels[i] = UInt16(min(65535, (sum[i] * 257).rounded())) }
        return try #require(context.makeImage())
    }

    /// Camera Raw's Saturation mixes channels: each output channel follows all three inputs. With the channels stepped
    /// together it banded a smooth colored ramp; stepped channel by channel, and fitted across its 8-bit wobble, it
    /// stays smoother than even its preview's average.
    @Test func cameraRawSaturationStaysSmooth() throws {
        let context = try DeepLayer.context(width: Self.width, height: Self.height)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt16.self)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let t = Double(x) / Double(Self.width - 1), i = (y * Self.width + x) * 4
                pixels[i] = UInt16(((100 + 4 * t) / 255 * 65535).rounded())
                pixels[i + 1] = UInt16(((90 + 3 * t) / 255 * 65535).rounded())
                pixels[i + 2] = UInt16(((120 + 5 * t) / 255 * 65535).rounded())
                pixels[i + 3] = 65535
            }
        }
        let ramp = try #require(context.makeImage())
        var settings = CameraRawSettings()
        settings.saturation = 100
        settings.vibrance = 100
        let mixed = try DeepLayer.run(ramp, mixesChannels: true) { try settings.apply($0) }
        let plain = try DeepLayer.run(ramp) { try settings.apply($0) }
        // Camera Raw at 8 bits on randomly dithered copies, averaged: what its preview shows once the noise is averaged
        // out. It wobbles a little from one 8-bit value to the next, and that's what bands once stretched.
        let preview = try reference(ramp) { try settings.apply($0) }
        var smooth = 0.0, together = 0.0, wobble = 0.0
        for channel in 0..<3 {
            smooth = max(smooth, try bends(mixed, channel: channel))
            together = max(together, try bends(plain, channel: channel))
            wobble = max(wobble, try bends(preview, channel: channel))
        }
        // Near the preview's own (whose average is random, so a fixed bound), and well under the bands it had.
        #expect(smooth < 0.45 && smooth < together / 3,
                "bends of \(smooth) steps, \(together) with the channels stepped together, \(wobble) in the preview")
        #expect(try row(mixed) != row(ramp), "saturated")
    }

    /// Convert to 16-Bit on a blank layer gives it clear 16-bit pixels; a gradient drawn on it then comes out at 16 bits,
    /// where 8 bits could only hold a few levels of a gentle one. Convert to 8-Bit dithers it back down, and undo returns.
    @Test func blankLayersConvertToSixteenBitsForSmoothGradients() async throws {
        let session = EditorSession()
        session.createDocument(width: Self.width, height: Self.height)
        session.addBlankLayer()
        #expect(session.activeLayer?.asset == nil && session.canConvertToSixteenBit && !session.canConvertToEightBit)
        session.convertLayers(toSixteenBit: true)
        #expect(session.activeLayer?.depthLabel == "16-Bit")
        // A gentle gradient: black to a dark gray, only 16 8-bit levels across the canvas.
        session.foregroundColor = .black
        session.backgroundColor = PaletteColor(red: 16 / 255, green: 16 / 255, blue: 16 / 255)
        session.selectTool(.gradient)
        session.gradientSettings.style = .foregroundToBackground
        session.beginGradient(at: CGPoint(x: 0.5, y: 4))
        session.moveGradient(end: CGPoint(x: Double(Self.width) - 0.5, y: 4))
        session.endGradientDrag()
        await session.commitGradient()
        let asset = try #require(session.activeLayer?.asset)
        let deep = try #require(try DeepLayer.flattened(asset), "the gradient kept the layer 16-bit")
        let values = try row(deep)
        #expect(Set(values).count > 100, "a smooth gradient: \(Set(values).count) distinct values, not 16 levels")
        session.convertLayers(toSixteenBit: false)
        #expect(session.activeLayer?.asset?.deep == nil && session.activeLayer?.depthLabel == nil)
        session.undo()
        #expect(session.activeLayer?.asset?.deep != nil, "undo brings the 16 bits back")
    }

    /// With several layers selected, Convert to 16-Bit / 8-Bit converts them all, and those in a selected folder, in one
    /// step; layers already at that depth, and ones not selected, are left as they are.
    @Test func convertingSeveralLayersConvertsThemAllInOneStep() throws {
        let session = EditorSession()
        session.createDocument(width: Self.width, height: Self.height)
        for _ in 0..<4 { session.addBlankLayer() }
        let ids = try #require(session.document?.layers.map(\.id))
        session.selectLayer(ids[1])
        session.convertLayers(toSixteenBit: true)
        session.selectLayers([ids[2]], primary: ids[2])
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.selectLayers([ids[1], folder], primary: folder)
        #expect(session.canConvertToSixteenBit && session.canConvertToEightBit, "a mix of 8- and 16-bit")
        session.convertLayers(toSixteenBit: true)
        func deep(_ id: UUID) -> Bool { session.document?.layers.first { $0.id == id }?.asset?.deep != nil }
        #expect(deep(ids[1]) && deep(ids[2]) && !deep(ids[0]) && !deep(ids[3]), "the selection and the folder's layer")
        #expect(!session.canConvertToSixteenBit)
        session.undo()
        #expect(deep(ids[1]) && !deep(ids[2]), "one undo step")
        session.redo()
        session.selectLayers([ids[1], folder], primary: folder)
        session.convertLayers(toSixteenBit: false)
        #expect(!deep(ids[1]) && !deep(ids[2]))
    }

    /// An 8-bit layer converted to 16 bits keeps its pixels exactly; a steep Levels afterwards is then worked at 16 bits.
    @Test func eightBitLayersConvertToSixteenBits() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.convertLayers(toSixteenBit: false)
        let eight = try #require(session.activeLayer?.asset)
        #expect(eight.deep == nil)
        session.convertLayers(toSixteenBit: true)
        let sixteen = try #require(session.activeLayer?.asset)
        let deep = try #require(sixteen.deep)
        #expect(try row(deep) == row(try DeepLayer.image(eight.image)), "the same pixels, now 16-bit")
    }

    // MARK: HDR

    /// An OpenEXR file as a render saves one: linear light, a gray ramp left to right with the right half rising past
    /// white to `peak` times as bright.
    private func exr(peak: Float) throws -> URL {
        let width = Self.width, height = Self.height
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = Float(x) / Float(width - 1) * peak, i = (y * width + x) * 4
                floats[i] = value; floats[i + 1] = value; floats[i + 2] = value
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".exr")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.openEXR.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The brightest value in a layer's HDR pixels (1 is white).
    private func peak(_ deep: CGImage) throws -> Float {
        let context = try DeepLayer.hdr(deep)
        let data = try #require(context.data)
        return withExtendedLifetime(context) {
            deep_half_peak(data.assumingMemoryBound(to: UInt16.self), context.bytesPerRow, deep.width, deep.height)
        }
    }

    /// A render brighter than white comes in as an HDR layer: its highlights kept, shown as plain white.
    @Test func exrHighlightsComeInAsAnHDRLayer() async throws {
        let url = try exr(peak: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let layer = try #require(session.activeLayer)
        let asset = try #require(layer.asset)
        #expect(asset.isHDR && layer.depthLabel == "HDR")
        // Linear 4 is about 1.8 in extended sRGB's gamma-encoded terms.
        let brightest = try peak(try #require(asset.deep))
        #expect(brightest > 1.5, "highlights kept: \(brightest)")
        #expect(try row(asset.image).last! == 65535, "shown as white")
    }

    /// Floats that never pass white are an ordinary 16-bit layer.
    @Test func exrWithinWhiteComesInAsSixteenBits() async throws {
        let url = try exr(peak: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.deep != nil && !asset.isHDR && session.activeLayer?.depthLabel == "16-Bit")
    }

    /// Saved, an HDR layer is an EXR in the project, and comes back with its highlights; older versions can't hold one.
    @Test func hdrLayersSaveAsEXRAndReopen() async throws {
        let url = try exr(peak: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let before = try peak(try #require(session.activeLayer?.asset?.deep))
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.layers.first?.imageFile == "\(id.uuidString).exr")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: project) }
        try await ProjectStore.shared.save(snapshot, to: project)
        let loaded = try await ProjectStore.shared.load(from: project)
        let asset = try #require(loaded.images[id])
        #expect(asset.isHDR)
        let after = try peak(try #require(asset.deep))
        #expect(abs(after - before) < 0.01, "highlights kept: \(before) then \(after)")
        var older = snapshot.manifest
        older.version = 12
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: project) }
    }

    /// An HDR layer whose highlights have all been painted over still saves as EXR, which reopens as a 16-bit layer,
    /// whose file is PNG: the next save encodes it as one rather than writing the EXR it was read from under the
    /// PNG's name, which no open could read.
    @Test func aDemotedEXRSavesAsPNGNotItsHeldBytes() async throws {
        // Float pixels within white, as painting over every highlight leaves an HDR layer's.
        let context = try DeepLayer.context(width: Self.width, height: Self.height, hdr: true)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let deep = try #require(context.makeImage())
        let shown = try DeepLayer.dithered(try DeepLayer.image(deep))
        let session = EditorSession()
        session.createDocument(width: Self.width, height: Self.height)
        session.insert(ImportedImage(image: shown, thumbnail: shown, name: "HDR", deep: deep))
        let id = try #require(session.activeLayerID)
        #expect(session.activeLayer?.asset?.isHDR == true)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: project) }
        let encoded = EncodedImages()
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: project, encoded: encoded)
        let loaded = try await ProjectStore.shared.load(from: project, encoded: encoded)
        let reopened = try #require(loaded.images[id])
        #expect(reopened.deep != nil && !reopened.isHDR, "within white, so 16-bit")
        session.installProject(loaded, from: project)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.layers.first?.imageFile == "\(id.uuidString).png")
        try await ProjectStore.shared.save(snapshot, to: project, encoded: encoded)
        #expect(encoded.encoded == 2, "encoded as PNG, not written as the EXR it was read from")
        let again = try #require(try await ProjectStore.shared.load(from: project, encoded: encoded).images[id])
        #expect(try row(try #require(again.deep)) == row(try #require(reopened.deep)), "pixel for pixel")
    }

    /// An imported HDR render (linear light up to 4× white), with its brightest value.
    private func hdrSession() async throws -> (EditorSession, URL, Float) {
        let url = try exr(peak: 4)
        let session = EditorSession()
        await session.importImages([url])
        return (session, url, try peak(try #require(session.activeLayer?.asset?.deep)))
    }

    /// Exposure turned down on an HDR layer works on its full range exactly: the highlights come down into view rather
    /// than having been clipped. One stop down, linear 4 becomes 2: still brighter than white.
    @Test func exposureBringsHighlightsIntoView() async throws {
        let (session, url, before) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginFilter(.exposure)
        var settings = FilterSettings()
        settings.exposure.exposure = -1
        session.updateFilter(settings, preview: true)
        await session.commitFilter()
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.isHDR, "still brighter than white")
        let after = try peak(try #require(asset.deep))
        // Linear 2 in extended sRGB's encoding (white is 1).
        let expected = Float(1.055 * pow(2, 1 / 2.4) - 0.055)
        #expect(abs(after - expected) < 0.01, "linear 4 to 2: \(before) became \(after), expected \(expected)")
        // Part of what showed as white now shows: values between 1 and 2 times white came down within it.
        let shown = try row(asset.image)
        #expect(shown.filter { $0 == 65535 }.count < Self.width / 2, "fewer pixels at white")
    }

    /// Levels pulling white down dims an HDR layer's highlights in proportion rather than clipping them.
    @Test func levelsDimsHighlightsInProportion() async throws {
        let (session, url, before) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginLevels()
        var settings = LevelsSettings()
        settings.ranges[0].outputWhite = 127.5
        session.updateLevels(settings, preview: true)
        await session.commitLevels()
        let after = try peak(try #require(session.activeLayer?.asset?.deep))
        #expect(abs(after - before / 2) < 0.02, "halved: \(before) became \(after)")
    }

    /// Blur, Hue/Saturation, a brush stroke and a merge all keep an HDR layer HDR, its highlights where they were.
    @Test func editsKeepHDRLayersHDR() async throws {
        let (session, url, before) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        func kept(_ step: String) throws {
            let asset = try #require(session.activeLayer?.asset)
            #expect(asset.isHDR, "\(step) kept the layer HDR")
            let now = try peak(try #require(asset.deep))
            #expect(abs(now - before) < 0.05, "\(step) kept the highlights: \(before) became \(now)")
        }
        session.beginFilter(.gaussianBlur)
        session.updateFilter(FilterSettings(radius: 1), preview: true)
        await session.commitFilter()
        try kept("Gaussian Blur")
        session.beginHueSaturation()
        session.updateHueSaturation(HueSaturationSettings(saturation: 40), preview: true)
        await session.commitHueSaturation()
        try kept("Hue/Saturation")
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 4, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 10, y: 4))
        session.continueBrush(at: CGPoint(x: 14, y: 4))
        await session.finishBrush()
        try kept("painting")
        session.addBlankLayer()
        session.beginBrush(at: CGPoint(x: 20, y: 4))
        session.continueBrush(at: CGPoint(x: 24, y: 4))
        await session.finishBrush()
        session.mergeLayers()
        try kept("merging")
    }

    /// A blur's preview on an HDR layer is made from its HDR pixels, as OK makes the result, so the two look the same:
    /// made from the copy clipped to white, the preview's glow was far fainter than the one OK left.
    @Test(arguments: [FilterKind.gaussianBlur, .motionBlur])
    func hdrBlurPreviewsMatchTheResult(kind: FilterKind) async throws {
        let (session, url, _) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        session.beginFilter(kind)
        var settings = FilterSettings(radius: 6)
        settings.distance = 20
        session.updateFilter(settings, preview: true)
        let edit = try #require(session.filterEdit)
        let hdr = try #require(edit.hdrPreviewSource, "previewed from the HDR pixels")
        let preview = try DeepLayer.dithered(try PixelFilter.previewHDR(edit.previewJob, from: hdr))
        let clipped = try DeepLayer.image(try PixelFilter.run(edit.previewJob))
        await session.commitFilter()
        let result = try #require(session.activeLayer?.asset?.image)
        #expect(preview.width == result.width && preview.height == result.height)
        func mean(_ a: CGImage, _ b: CGImage) throws -> Double {
            let x = try row(a), y = try row(b)
            return zip(x, y).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(x.count) / 257
        }
        let matched = try mean(preview, result), before = try mean(clipped, result)
        #expect(matched < 1.5 && matched < before / 3, "\(kind): \(matched) steps off the result, \(before) from the clipped copy")
    }

    /// Exported as EXR, an HDR document keeps its highlights; an Exposure adjustment layer over it works on them exactly.
    @Test func hdrDocumentsExportAsEXR() async throws {
        let (session, url, before) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        func exported() async throws -> Float {
            let snapshot = try #require(session.projectSnapshot())
            let raster = try await ImageExporter.shared.render(snapshot, sixteenBit: true, hdr: true)
            let data = try await ImageExporter.shared.exrData(raster)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.openEXR.identifier)
            return try peak(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        let whole = try await exported()
        #expect(abs(whole - before) < 0.02, "highlights kept: \(before) exported as \(whole)")
        session.addAdjustment(.exposure)
        let id = try #require(session.activeLayerID)
        var adjustment = try #require(session.activeLayer?.adjustment)
        adjustment.exposure.exposure = -1
        session.updateAdjustment(id, value: adjustment)
        let dimmed = try await exported()
        let expected = Float(1.055 * pow(2, 1 / 2.4) - 0.055)
        #expect(abs(dimmed - expected) < 0.02, "one stop down: linear 4 to 2, \(dimmed) against \(expected)")
    }

    /// The canvas's adjustments over an HDR layer keep what's brighter than white, as a merge or export does: Exposure
    /// works on the full range, and Levels dims a highlight in proportion. Transparency is left as it was.
    @Test @MainActor func gpuAdjustmentsKeepHighlights() throws {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        // Linear 2 (encoded about 1.35), opaque; and a half-transparent mid gray.
        let bright = Float(1.055 * pow(2, 1 / 2.4) - 0.055)
        func pixel(_ value: Float, alpha: Float) -> CIImage {
            // A CIColor's components are straight, not premultiplied.
            CIImage(color: CIColor(red: CGFloat(value), green: CGFloat(value), blue: CGFloat(value),
                                   alpha: CGFloat(alpha), colorSpace: DeepLayer.hdrSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        func read(_ image: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: 4)
            renderer.context.render(image, toBitmap: &out, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
            return out
        }
        var exposure = LayerAdjustment(kind: .exposure)
        exposure.exposure.exposure = -1
        let dimmed = try #require(GPUAdjustment.apply(exposure, to: pixel(bright, alpha: 1), scale: 1, mapping: .identity, hdr: true))
        #expect(abs(read(dimmed)[0] - 1) < 0.01, "linear 2 one stop down is white: \(read(dimmed))")
        var levels = LayerAdjustment(kind: .levels)
        levels.levels.ranges[0].outputWhite = 127.5
        let halved = try #require(GPUAdjustment.apply(levels, to: pixel(bright, alpha: 1), scale: 1, mapping: .identity, hdr: true))
        #expect(abs(read(halved)[0] - bright / 2) < 0.01, "a highlight halved: \(read(halved))")
        let soft = try #require(GPUAdjustment.apply(levels, to: pixel(0.5, alpha: 0.5), scale: 1, mapping: .identity, hdr: true))
        let values = read(soft)
        #expect(abs(values[3] - 0.5) < 0.01 && abs(values[0] - 0.125) < 0.01, "coverage kept, color halved: \(values)")
    }

    /// The canvas draws an HDR layer from its own pixels, uploaded as half floats: its highlights reach the GPU.
    @Test @MainActor func hdrLayersReachTheCanvasWithTheirHighlights() async throws {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        let (session, url, before) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try #require(session.activeLayer?.asset)
        let shown = try #require(DeepLayer.canvasImage(asset))
        let texture = try #require(renderer.image(shown))
        var out = [Float](repeating: 0, count: 4)
        // The ramp's brightest column, at the right.
        renderer.context.render(texture, toBitmap: &out, rowBytes: 16,
                                bounds: CGRect(x: shown.width - 1, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: DeepLayer.hdrSpace)
        #expect(abs(out[0] - before) < 0.02, "the brightest value \(before) reached the GPU as \(out[0])")
    }

    /// An HDR layer converts to 16 bits: clipped to white, then a 16-bit layer; undo brings the HDR back.
    @Test func hdrLayersConvertToSixteenBits() async throws {
        let (session, url, _) = try await hdrSession()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(session.canConvertToSixteenBit && session.canConvertToEightBit, "an HDR layer can go either way")
        session.convertLayers(toSixteenBit: true)
        let asset = try #require(session.activeLayer?.asset)
        #expect(asset.deep != nil && !asset.isHDR && session.activeLayer?.depthLabel == "16-Bit")
        #expect(try row(try #require(asset.deep)).last == 65535, "highlights clipped to white")
        session.undo()
        #expect(session.activeLayer?.asset?.isHDR == true)
    }

    /// The canvas draws a 16-bit layer from its 16-bit pixels too (a 16-bit texture), so an adjustment layer over it
    /// previews smooth, as it will export, rather than working on the dithered 8-bit copy.
    @Test @MainActor func sixteenBitLayersReachTheCanvasAtSixteenBits() async throws {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try #require(session.activeLayer?.asset)
        let shown = try #require(DeepLayer.canvasImage(asset))
        let texture = try #require(renderer.image(shown))
        let expected = try row(shown)
        var out = [Float](repeating: 0, count: Self.width * 4)
        renderer.context.render(texture, toBitmap: &out, rowBytes: Self.width * 16,
                                bounds: CGRect(x: 0, y: 0, width: Self.width, height: 1), format: .RGBAf,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var worst = 0.0
        for x in 0..<Self.width { worst = max(worst, abs(Double(out[x * 4]) * 65535 - Double(expected[x]))) }
        #expect(worst < 26, "within a tenth of an 8-bit step of the layer's own: worst \(worst / 257) steps")
    }

    /// The canvas dithers on its way to the 8-bit screen when a document has 16-bit or HDR layers: a tone between two
    /// levels comes out a mix of both rather than rounded into a band, and a tone on a level (all of an 8-bit image) comes
    /// out exactly itself.
    @Test @MainActor func theScreenIsDitheredNotRounded() throws {
        guard let renderer = GPUCanvasRenderer.shared else { return }
        func shown(_ level: Double) -> [UInt8] {
            let gray = CIImage(color: CIColor(red: level / 255, green: level / 255, blue: level / 255, alpha: 1,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            var out = [UInt8](repeating: 0, count: 64 * 64 * 4)
            renderer.context.render(GPUCanvasRenderer.dithered(gray), toBitmap: &out, rowBytes: 64 * 4,
                                    bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return stride(from: 0, to: out.count, by: 4).map { out[$0] }
        }
        #expect(Set(shown(100)) == [100], "a tone on a level is left exactly as it is")
        let between = shown(100.5)
        let high = Double(between.filter { $0 == 101 }.count) / Double(between.count)
        #expect(Set(between) == [100, 101] && abs(high - 0.5) < 0.15, "halfway: half of each, \(Int(high * 100))% up")
    }

    /// A version-11 project can't carry 16-bit pixels: older builds would misread them.
    @Test func olderVersionsCannotHoldSixteenBitImages() async throws {
        let (session, url) = try await importedSession()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: project) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: project)
        let manifest = project.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: "\"version\" : \(ProjectManifest.current)", with: "\"version\" : 11")
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: project) }
    }
}
