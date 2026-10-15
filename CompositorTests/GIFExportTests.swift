import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct GIFExportTests {
    private func reader(_ data: Data) throws -> CGImageSource {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        return source
    }

    private func pixel(_ source: CGImageSource, frame: Int, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, frame, nil))
        return try ImageImportTests().rgba(image, x: x, y: y)
    }

    private func mask(width: Int, height: Int, revealing rect: CGRect) throws -> LayerMask {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        return LayerMask(asset: try LayerMask.asset(from: #require(context.makeImage())))
    }

    @Test func editedCopiesOrderMasksAndCanvasLayersExportFromAReopenedProject() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("GIFExport-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        #expect(session.finishBrushImmediately())
        await session.duplicateGIFFrame(at: 1, for: id)
        await session.deleteGIFFrame(at: 1, for: id)
        session.moveGIFFrame(at: 3, to: 0, for: id)
        session.document?.layers[0].mask = try mask(width: 32, height: 24,
            revealing: CGRect(x: 0, y: 0, width: 32, height: 16))
        session.document?.layers[0].gifFrameMasks[4] = try mask(width: 32, height: 24,
            revealing: CGRect(x: 0, y: 0, width: 16, height: 24))
        var disabled = try #require(LayerMask.solid(revealing: false))
        disabled.isEnabled = false
        session.document?.layers[0].gifFrameMasks[2] = disabled
        let original = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(original, to: package)
        try FileManager.default.removeItem(at: url)
        let reopened = try await ProjectStore.shared.load(from: package)
        var images = reopened.images
        let overlayID = UUID()
        let context = try BrushRaster.context(width: 1, height: 1, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let white = try #require(context.makeImage())
        images[overlayID] = ImportedImage(image: white, thumbnail: white, name: "Overlay")
        var manifest = reopened.manifest
        manifest.layers.append(ProjectLayerRecord(id: overlayID, name: "Overlay", isVisible: true,
            transform: LayerTransform(origin: CGPoint(x: 28, y: 2), size: CGSize(width: 4, height: 4)), imageFile: "overlay.png"))
        let snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: reopened.masks,
            animations: reopened.animations, frameMasks: reopened.frameMasks)
        let before = session.document
        let count = session.history.undoCount
        let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions(layerID: id))
        let source = try reader(result.data)
        #expect(CGImageSourceGetCount(source) == 4)
        #expect(result.durations == [0.24, 0.04, 0.16, 0.08])
        let decoded = try GIFDecoder.source(result.data, name: "Exported")
        #expect(decoded.frames.map(\.duration) == result.durations)
        #expect(try pixel(source, frame: 0, x: 24, y: 12)[0] > 220)
        #expect(try pixel(source, frame: 0, x: 24, y: 12)[1] > 220)
        #expect(try pixel(source, frame: 1, x: 24, y: 12)[0] > 220)
        #expect(try pixel(source, frame: 2, x: 8, y: 12) == [0, 0, 0, 255])
        #expect(try pixel(source, frame: 2, x: 4, y: 12)[2] > 220)
        #expect(try pixel(source, frame: 2, x: 24, y: 12)[3] == 0)
        #expect(try pixel(source, frame: 3, x: 24, y: 12)[3] == 255)
        for frame in 0..<4 {
            #expect(try pixel(source, frame: frame, x: 8, y: 20)[3] == 0)
            #expect(try pixel(source, frame: frame, x: 30, y: 4) == [255, 255, 255, 255])
        }
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.gifTimelineSelectedFrameIndex == 4)
        let exportedURL = FileManager.default.temporaryDirectory.appendingPathComponent("GIFExport-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        try Data("old".utf8).write(to: exportedURL)
        try await ImageExporter.shared.write(result.data, to: exportedURL)
        #expect(try Data(contentsOf: exportedURL) == result.data)
    }

    @Test func smallTransparentMovingAndEmptyFramesHaveNoTrailsAndKeepOrientation() async throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 4, nil))
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFHasGlobalColorMap: false]] as CFDictionary)
        for index in 0..<4 {
            let context = try BrushRaster.context(width: 4, height: 2, mask: false)
            context.setFillColor(CGColor(srgbRed: index == 0 ? 1 : 0, green: index == 1 ? 1 : 0, blue: index == 2 ? 1 : 0, alpha: 1))
            if index == 0 { context.fill(CGRect(x: 0, y: 0, width: 2, height: 1)) }
            if index == 1 { context.fill(CGRect(x: 0, y: 0, width: 4, height: 2)) }
            if index == 2 { context.fill(CGRect(x: 2, y: 1, width: 2, height: 1)) }
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: [0.02, 0.03, 0.05, 0.1][index]]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let animation = GIFAnimation(source: try GIFDecoder.source(data as Data, name: "Moving"))
        let id = UUID()
        let asset = try GIFDecoder.frame(animation, index: 0, name: "Moving")
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 4, height: 2,
            activeLayerID: id, layers: [ProjectLayerRecord(id: id, name: "Moving", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 2)), imageFile: "frame.png",
                gif: ProjectGIFRecord(sourceFile: "source.gif", selectedFrameIndex: 0))]),
            images: [id: asset], animations: [id: animation])
        for forever in [true, false] {
            let result = try await GIFExporter.shared.encode(snapshot, width: 4, height: 2,
                options: GIFExportOptions(layerID: id, loopsForever: forever))
            let source = try reader(result.data)
            #expect(CGImageSourceGetCount(source) == 4 && result.durations == [0.02, 0.03, 0.05, 0.1])
            #expect(try pixel(source, frame: 0, x: 0, y: 0)[0] > 220)
            #expect(try pixel(source, frame: 0, x: 0, y: 1)[3] == 0)
            #expect(try pixel(source, frame: 1, x: 0, y: 0)[1] > 220)
            #expect(try pixel(source, frame: 2, x: 0, y: 0)[3] == 0)
            #expect(try pixel(source, frame: 2, x: 3, y: 1)[2] > 220)
            #expect(try pixel(source, frame: 3, x: 3, y: 1)[3] == 0)
            #expect((result.data.range(of: Data("NETSCAPE2.0".utf8)) != nil) == forever)
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            if forever { #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0) }
        }
    }

    @Test func stillGIFResizingAlphaThresholdAndMatte() async throws {
        let context = try BrushRaster.context(width: 4, height: 4, mask: false)
        for (x, alpha) in [(0, 0.25), (1, 0.75), (2, 1.0)] {
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 4))
        }
        let image = try #require(context.makeImage()), id = UUID()
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 4, height: 4,
            activeLayerID: id, layers: [ProjectLayerRecord(id: id, name: "Still", isVisible: true,
                transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)), imageFile: "still.png")]),
            images: [id: ImportedImage(image: image, thumbnail: image, name: "Still")])
        let transparent = try await GIFExporter.shared.encode(snapshot, width: 4, height: 4, options: GIFExportOptions())
        let source = try reader(transparent.data)
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(try pixel(source, frame: 0, x: 0, y: 0)[3] == 0)
        #expect(try pixel(source, frame: 0, x: 1, y: 0)[0] > 220)
        #expect(try pixel(source, frame: 0, x: 1, y: 0)[3] == 255)
        let matte = try await GIFExporter.shared.encode(snapshot, width: 8, height: 8,
            options: GIFExportOptions(keepsTransparency: false, red: 0, green: 1, blue: 0))
        let matteSource = try reader(matte.data)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(matteSource, 0, nil))
        #expect(decoded.width == 8 && decoded.height == 8)
        #expect(try pixel(matteSource, frame: 0, x: 7, y: 7)[1] > 220)
        #expect(try pixel(matteSource, frame: 0, x: 7, y: 7)[3] == 255)
        let blank = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 1, height: 1,
            activeLayerID: nil, layers: []), images: [:])
        let tiny = try await GIFExporter.shared.encode(blank, width: 1, height: 1, options: GIFExportOptions())
        #expect(try pixel(reader(tiny.data), frame: 0, x: 0, y: 0)[3] == 0)
    }

    @Test func otherGIFLayersRemainAtTheirCapturedFrames() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let first = try #require(session.activeLayerID)
        await session.importImages([url])
        let second = try #require(session.activeLayerID)
        await session.selectGIFTimelineFrame(1)
        session.document?.layers[0].transform.size = CGSize(width: 16, height: 24)
        session.document?.layers[1].transform = LayerTransform(origin: CGPoint(x: 16, y: 0), size: CGSize(width: 16, height: 24))
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.gifExportLayers.map(\.id) == [first, second])
        let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions(layerID: first))
        let source = try reader(result.data)
        for index in 0..<4 { #expect(try pixel(source, frame: index, x: 24, y: 12)[2] > 220) }
        #expect(try pixel(source, frame: 0, x: 8, y: 12)[0] > 220)
        #expect(try pixel(source, frame: 2, x: 8, y: 12)[1] > 220)
        #expect(session.gifTimelineSelectedFrameIndex == 1 && session.activeLayerID == second)
    }

    @Test func invalidTimelineOversizedSequenceAndCancellationFailBeforeWriting() async throws {
        let url = try GIFFrameDeletionTests().fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        let snapshot = try #require(session.projectSnapshot())
        await #expect(throws: GIFExportError.self) {
            try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions(layerID: UUID()))
        }
        await #expect(throws: GIFExportError.self) {
            try await GIFExporter.shared.encode(snapshot, width: 10_000, height: 10_000, options: GIFExportOptions(layerID: id))
        }
        await #expect(throws: ExportError.self) {
            try await GIFExporter.shared.encode(snapshot, width: -1, height: 24, options: GIFExportOptions())
        }
        var animations = snapshot.animations
        animations[id]?.frameOrder = []
        let invalid = ProjectSnapshot(manifest: snapshot.manifest, images: snapshot.images, animations: animations)
        await #expect(throws: GIFExportError.self) {
            try await GIFExporter.shared.encode(invalid, width: 32, height: 24, options: GIFExportOptions(layerID: id))
        }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GIFExporter.shared.encode(snapshot, width: 32, height: 24, options: GIFExportOptions(layerID: id))
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        let canceledDuringEncoding = Task {
            try await GIFExporter.shared.encode(snapshot, width: 32, height: 24,
                options: GIFExportOptions(layerID: id)) { completed, _ in
                if completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await canceledDuringEncoding.value }
    }
}
