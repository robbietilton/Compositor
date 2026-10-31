import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

/// Animated GIF layers: import, editing one frame, duplicating and deleting frames, timing, saving and export.
@MainActor
struct GIFLayerTests {
    /// Four solid frames, red, blue, green and yellow, each with its own delay.
    func fixture(delays: [TimeInterval] = [0.04, 0.16, 0.08, 0.24]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gif")
        let colors: [CGColor] = [.init(red: 1, green: 0, blue: 0, alpha: 1), .init(red: 0, green: 0, blue: 1, alpha: 1),
                                 .init(red: 0, green: 1, blue: 0, alpha: 1), .init(red: 1, green: 1, blue: 0, alpha: 1)]
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, colors.count, nil))
        for (index, color) in colors.enumerated() {
            let context = try BrushRaster.context(width: 32, height: 24, mask: false)
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index]]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The middle pixel's red, green and blue.
    private func color(_ image: CGImage?) throws -> [Int] {
        let image = try #require(image)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { Int(bytes[$0]) }
    }

    /// Whether two colors match within a little rounding.
    private func near(_ actual: [Int], _ expected: [Int]) -> Bool {
        zip(actual, expected).allSatisfy { abs($0 - $1) <= 8 }
    }

    private func imported() async throws -> (session: EditorSession, id: UUID, url: URL) {
        let url = try fixture()
        let session = EditorSession()
        await session.importImages([url])
        return (session, try #require(session.activeLayerID), url)
    }

    @Test func aGIFImportsAsOneTaggedLayerWithItsFramesAndTiming() async throws {
        let (session, _, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(session.document?.layers.count == 1)
        let layer = try #require(session.activeLayer)
        #expect(layer.gifAnimation != nil && layer.depthLabel == "GIF")
        #expect(session.gifTimelineFrames.map(\.index) == [0, 1, 2, 3])
        #expect(session.gifTimelineFrames.map(\.duration) == [0.04, 0.16, 0.08, 0.24])
        #expect(session.gifTimelineTiming.mode == .perFrame && session.gifTimelineCanPlay)
    }

    @Test func anEditChangesOnlyTheShownFrameAndUndoes() async throws {
        let (session, id, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        await session.selectGIFTimelineFrame(1)
        let blue = try color(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(blue[2] > 200 && blue[0] < 60 && blue[1] < 80, "shows \(blue)")
        await session.invertPixels()
        #expect(session.activeLayer?.gifAnimation?.framePixels.keys.sorted() == [1])
        let inverted = try color(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(near(inverted, blue.map { 255 - $0 }), "shows \(inverted)")
        await session.selectGIFTimelineFrame(2)
        let green = try color(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        #expect(green[1] > 200 && green[0] < 60 && green[2] < 80, "other frames untouched, shows \(green)")
        session.undo()
        #expect(session.activeLayer?.gifAnimation?.framePixels.isEmpty == true)
        _ = id
    }

    @Test func framesDuplicateBesideThemselvesAndDeleteDownToOne() async throws {
        let (session, id, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        await session.duplicateGIFFrame(at: 0, for: id)
        let frames = session.gifTimelineFrames.map(\.index)
        #expect(frames.count == 5 && frames[0] == 0 && frames[2] == 1, "the copy sits right after the original")
        #expect(session.gifTimelineSelectedFrameIndex == frames[1])
        for index in frames.dropLast() { await session.deleteGIFFrames(at: [index], for: id) }
        #expect(session.gifTimelineFrames.count == 1)
        await session.deleteGIFFrames(at: [frames.last!], for: id)
        #expect(session.gifTimelineFrames.count == 1, "the last frame stays")
        #expect(!session.gifTimelineCanPlay)
    }

    @Test func oneDelayForEveryFrameOrTheGIFsOwn() async throws {
        let (session, id, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = session.gifTimelineFrames
        var timing = session.gifTimelineTiming
        timing.mode = .uniform
        timing.uniformDelay = 0.1
        session.setGIFFrameTiming(timing, for: id)
        #expect(frames.allSatisfy { session.gifTimelineTiming.delay(for: $0) == 0.1 })
        timing.mode = .perFrame
        session.setGIFFrameTiming(timing, for: id)
        #expect(frames.map { session.gifTimelineTiming.delay(for: $0) } == [0.04, 0.16, 0.08, 0.24])
    }

    @Test func editedFramesTimingAndCopiesSurviveSaving() async throws {
        let (session, id, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        await session.selectGIFTimelineFrame(1)
        await session.invertPixels()
        await session.duplicateGIFFrame(at: 1, for: id)
        var timing = session.gifTimelineTiming
        timing.mode = .uniform
        timing.uniformDelay = 0.2
        session.setGIFFrameTiming(timing, for: id)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("GIF-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: project) }
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == ProjectManifest.current)
        try await ProjectStore.shared.save(snapshot, to: project)
        let loaded = try await ProjectStore.shared.load(from: project)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: project)
        let layer = try #require(reopened.document?.layers.first)
        #expect(layer.gifAnimation?.frames.count == 5)
        #expect(layer.gifAnimation?.timing.mode == .uniform && layer.gifAnimation?.timing.uniformDelay == 0.2)
        #expect(Set(layer.gifAnimation?.framePixels.keys ?? [:].keys).count == 2, "the edited frame and its copy")
        var older = snapshot.manifest
        older.version = 16
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images, masks: snapshot.masks,
                                                               animations: snapshot.animations), to: project)
        }
    }

    @Test func exportWritesEveryFrameWithItsDelay() async throws {
        let (session, _, url) = try await imported()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions()) { _, _ in }
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 4)
        let delays = (0..<4).map { index -> Double in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        #expect(delays == [0.04, 0.16, 0.08, 0.24])
        #expect(result.durations == [0.04, 0.16, 0.08, 0.24])
    }
}
