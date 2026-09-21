import AppKit
import SwiftUI
import Testing
@testable import Compositor

@MainActor
struct LevelsTests {
    private func image(_ pixels: [[UInt8]]) throws -> CGImage {
        let data = Data(pixels.flatMap { $0 })
        return try #require(CGImage(width: pixels.count, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: pixels.count * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 6, height: 1)
        let source = try image([[0,0,0,255], [64,64,64,255], [128,128,128,255], [255,255,255,255], [64,32,0,128], [0,0,0,0]])
        session.insert(ImportedImage(image: source, thumbnail: source, name: "Ramp"))
        return session
    }
    private func job(_ image: CGImage, _ settings: LevelsSettings = LevelsSettings(), selection: SelectionClip? = nil) -> LevelsJob {
        LevelsJob(image: image, settings: settings, selection: selection, mapping: .identity)
    }
    @Test func identityAndChannelSelectionAreExactNoOps() async throws {
        let session = try session(), before = session.document
        let source = try #require(session.activeLayer?.asset?.image)
        #expect(try LevelsFilter.run(job(source)) === source)
        let count = session.history.undoCount
        session.beginLevels()
        var settings = LevelsSettings(); settings.channel = .blue
        session.updateLevels(settings, preview: true)
        #expect(!session.canEditLayers && !session.canUseHistory && !session.canStartProjectOperation)
        await session.commitLevels()
        #expect(session.document == before && session.history.undoCount == count && session.levels == nil)
    }
    @Test func inputClippingGammaOutputInversionAndAlpha() throws {
        let source = try image([[0,0,0,255], [64,64,64,255], [128,128,128,255], [255,255,255,255], [64,32,0,128], [0,0,0,0]])
        var settings = LevelsSettings()
        settings.current = LevelRange(black: 64, gamma: 1, white: 128)
        let clipped = try bytes(LevelsFilter.run(job(source, settings)))
        #expect(Array(clipped[0..<12]) == [0,0,0,255, 0,0,0,255, 255,255,255,255])
        settings.current = LevelRange(gamma: 2)
        let brightened = try bytes(LevelsFilter.run(job(source, settings)))
        #expect(abs(Int(brightened[4]) - 128) <= 1)
        #expect(abs(Int(brightened[8]) - 181) <= 1)
        #expect(brightened[19] == 128 && brightened[23] == 0)
        #expect(brightened[16] <= 128 && brightened[17] <= 128)
        settings.current = LevelRange(outputBlack: 255, outputWhite: 0)
        let inverted = try bytes(LevelsFilter.run(job(source, settings)))
        #expect(inverted[0] == 255 && inverted[12] == 0)
        #expect(inverted[16] == 64 && inverted[17] == 96 && inverted[18] == 128 && inverted[19] == 128,
                "premultiplied [64,32,0,128] inverted: \(Array(inverted[16..<20]))")
    }
    @Test func channelsCoexistAndUseDocumentedOrder() throws {
        var settings = LevelsSettings()
        settings.channel = .red; settings.current = LevelRange(gamma: 2)
        settings.channel = .rgb; settings.current = LevelRange(black: 40, white: 210)
        let result = try bytes(LevelsFilter.run(job(image([[64,64,64,255]]), settings)))
        let expectedRed = LevelRange(black: 40, white: 210).apply(LevelRange(gamma: 2).apply(64.0/255))
        #expect(abs(Double(result[0]) - expectedRed * 255) <= 1)
        #expect(result[1] == result[2] && result[0] > result[1])
        let invalid = LevelRange(black: 300, gamma: .nan, white: -1, outputBlack: -100, outputWhite: 400).normalized
        #expect(invalid.black < invalid.white && invalid.gamma == 1 && invalid.outputBlack == 0 && invalid.outputWhite == 255)
    }
    @Test func histogramExcludesTransparencyAndWeightsSelection() throws {
        let source = try image([[255,0,0,255], [0,128,0,128], [0,0,0,0]])
        let bins = try LevelsFilter.histogram(job(source))
        #expect(bins[1][255] == 1 && abs(bins[2][255] - 128.0/255) < 0.00001)
        let total: Double = bins[0].reduce(0.0, +)
        let expectedTotal: Double = 1.0 + 128.0 / 255.0
        #expect(abs(total - expectedTotal) < 0.00001)
        let selection = try DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1), transform: nil), antialiased: false).clip(canvas: CGSize(width: 3, height: 1))
        let selected = try LevelsFilter.histogram(job(source, selection: selection))
        #expect(selected[1][255] == 1 && selected[2][255] == 0)
        let empty = try LevelsFilter.histogram(job(source, selection: SelectionClip(rect: .zero, coverage: nil)))
        #expect(empty.flatMap { $0 }.allSatisfy { $0 == 0 })
    }
    @Test func selectionPreviewCancelCommitUndoAndPersistence() async throws {
        let session = try session()
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 2, height: 1), transform: nil), mode: .replace, name: "Select")
        let before = session.document, count = session.history.undoCount
        session.beginLevels()
        let edit = try #require(session.levels)
        await edit.histogramTask?.value
        #expect(edit.histogramReady)
        var settings = LevelsSettings(); settings.current = LevelRange(outputBlack: 255, outputWhite: 0)
        session.updateLevels(settings, preview: true)
        await edit.previewTask?.value
        let preview = try bytes(#require(edit.preparedPreview))
        #expect(preview[0] == 255 && preview[8] == 128)
        #expect(session.document == before)
        session.updateLevels(settings, preview: false)
        #expect(edit.previewImage(for: edit.layerID) == nil)
        session.cancelLevels()
        #expect(session.document == before && session.history.undoCount == count)
        session.beginLevels(); session.updateLevels(settings, preview: false)
        await session.commitLevels()
        #expect(session.history.undoCount == count+1 && session.history.undoName == "Levels")
        let committed = try #require(session.activeLayer?.asset?.image)
        #expect(try bytes(committed) == preview)
        session.undo(); #expect(session.document == before)
        session.redo(); #expect(session.activeLayer?.asset?.image === committed)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Levels-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(#require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let result = try await ImageExporter.shared.render(loaded)
        #expect(try bytes(result.image) == preview)
    }
    @Test func stalePreviewCannotReturnAfterOffOrReopen() async throws {
        let session = try session()
        session.beginLevels()
        var settings = LevelsSettings(); settings.current = LevelRange(gamma: 2)
        session.updateLevels(settings, preview: true)
        let old = try #require(session.levels), task = old.previewTask
        session.updateLevels(settings, preview: false)
        await task?.value
        #expect(old.preparedPreview == nil)
        session.updateLevels(settings, preview: true)
        let second = old.previewTask
        session.cancelLevels(); session.beginLevels()
        await second?.value
        #expect(session.levels !== old && session.levels?.preparedPreview == nil)
        session.cancelLevels()
    }
    @Test func histogramDisplayKeepsDistributionVisibleBesideClippingSpikes() {
        var bins = Array(repeating: 100.0, count: 256)
        bins[255] = 100_000
        #expect(LevelsHistogramDisplay.scale(for: bins) == 400)
        bins[0] = 200_000
        #expect(LevelsHistogramDisplay.scale(for: bins) == 400)
        // An isolated spike away from the endpoints should not flatten the graph either.
        bins[128] = 500_000
        #expect(LevelsHistogramDisplay.scale(for: bins) == 400)
        #expect(bins[128] == 500_000) // Counts are never modified.
        #expect(LevelsHistogramDisplay.scale(for: Array(repeating: 100, count: 256)) == 100)
        var sparse = Array(repeating: 0.0, count: 256)
        #expect(LevelsHistogramDisplay.scale(for: sparse) == 0)
        sparse[255] = 50
        #expect(LevelsHistogramDisplay.scale(for: sparse) == 50)
        sparse[0] = 100
        #expect(LevelsHistogramDisplay.scale(for: sparse) == 100)
        sparse[128] = 200
        #expect(LevelsHistogramDisplay.scale(for: sparse) == 200)
    }
    @Test func autoAlgorithmsAndEyedropperCalibration() throws {
        var bins = Array(repeating: Array(repeating: 0.0, count: 256), count: 4)
        for c in 1...3 { bins[c][20*c] = 100; bins[c][200+c*10] = 100 }
        let linked = LevelsAuto.contrast.settings(histogram: bins)
        #expect(linked.ranges[0].black == 20 && linked.ranges[0].white == 230)
        let color = LevelsAuto.color.settings(histogram: bins)
        #expect(color.ranges[1].black == 20 && color.ranges[3].black == 60)
        #expect(color.ranges[0] == LevelRange())
        #expect(LevelsAuto.neutral.settings(histogram: bins).ranges[1].gamma == 1)
        let empty = Array(repeating: Array(repeating: 0.0, count: 256), count: 4)
        for mode in LevelsAuto.allCases { #expect(mode.settings(histogram: empty).isIdentity) }
        let rgb = [0.25, 0.4, 0.6]
        for mode in LevelsSample.allCases {
            let settings = LevelsSettings().sampling(rgb, mode: mode)
            let target: Double = mode == .black ? 0 : mode == .white ? 1 : 0.5
            for (i, channel) in [LevelsChannel.red, .green, .blue].enumerated() {
                #expect(abs(settings.apply(rgb[i], channel: channel) - target) < 0.0001)
            }
        }
    }
    @Test func eyedropperSamplesOriginalAndRejectsTransparentPixels() throws {
        let session = try session(); session.beginLevels()
        let edit = try #require(session.levels)
        edit.sampleMode = .gray
        session.sampleLevels(at: CGPoint(x: 2.5, y: 0.5))
        let first = edit.settings
        session.sampleLevels(at: CGPoint(x: 2.5, y: 0.5))
        #expect(edit.settings == first)
        session.sampleLevels(at: CGPoint(x: 5.5, y: 0.5))
        #expect(edit.settings == first)
        session.sampleLevels(at: CGPoint(x: -1, y: 0.5))
        #expect(edit.settings == first)
        session.cancelLevels()
    }
    @Test func panelPreview() async throws {
        guard ProcessInfo.processInfo.environment["LEVELS_PREVIEW"] == "1" else { return }
        let session = try session(); session.beginLevels()
        await session.levels?.histogramTask?.value
        let view = NSHostingView(rootView: LevelsSheet(session: session))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/compositor-levels-panel.png"))
        window.orderOut(nil); session.cancelLevels()
    }
}
