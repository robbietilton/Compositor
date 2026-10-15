import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ExportMaskTests {
    enum MaskState: CaseIterable, Sendable {
        case disabled, layerOnly, frameOnly, both
        var layerEnabled: Bool { self == .layerOnly || self == .both }
        var frameEnabled: Bool { self == .frameOnly || self == .both }
    }

    private func mask(revealing rect: CGRect? = nil, gray: CGFloat = 1, enabled: Bool = true) throws -> LayerMask {
        let context = try BrushRaster.context(width: 32, height: 24, mask: true)
        if let rect {
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(rect)
        }
        return LayerMask(asset: try LayerMask.asset(from: #require(context.makeImage())), isEnabled: enabled)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        try ImageImportTests().rgba(image, x: x, y: y)
    }

    @Test(arguments: [false, true])
    func HEICExportAsAndQuickPNGRespectLayerMaskVisibility(enabled: Bool) async throws {
        let url = try ImageImportTests().fixture(.heic)
        let quickPNG = FileManager.default.temporaryDirectory.appendingPathComponent("HEICMask-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: quickPNG) }
        let session = EditorSession()
        await session.importImages([url])
        session.document?.layers[0].mask = try mask(revealing: CGRect(x: 0, y: 0, width: 8, height: 24))
        session.document?.layers[0].mask?.isEnabled = enabled
        let snapshot = try #require(session.projectSnapshot()), before = session.document
        let count = session.history.undoCount
        let raster = try await ImageExporter.shared.render(snapshot)
        let png = try await ImageExporter.shared.pngData(raster)
        let jpeg = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions())
        for (data, transparent) in [(png, true), (jpeg.data, false)] {
            let reader = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            let shown = try pixel(image, x: 8, y: 12), hidden = try pixel(image, x: 24, y: 12)
            #expect(shown[0] > 200 && shown[1] < 50 && shown[2] < 50)
            if !enabled { #expect(hidden[0] > 200 && hidden[1] < 50 && hidden[2] < 50 && hidden[3] == 255) }
            else if transparent { #expect(hidden[3] == 0) }
            else { #expect(hidden.prefix(3).allSatisfy { $0 > 240 }) }
        }
        // Both export entry points render the ordinary snapshot with the captured enabled flags.
        try await ImageExporter.shared.exportPNG(snapshot, to: quickPNG)
        let reader = try #require(CGImageSourceCreateWithURL(quickPNG as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        #expect(try pixel(image, x: 24, y: 12)[3] == (enabled ? 0 : 255))
        #expect(session.document == before && session.history.undoCount == count)
        #expect(session.activeLayer?.mask?.isEnabled == enabled)
    }

    @Test(arguments: MaskState.allCases)
    func previewAndAnimationExportRespectLayerAndFrameMaskVisibility(state: MaskState) async throws {
        let url = try GIFFrameDeletionTests().fixture()
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("ExportMasks-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: package) }
        let session = EditorSession()
        await session.importImages([url])
        let id = try #require(session.activeLayerID)
        session.document?.layers[0].mask = try mask(revealing: CGRect(x: 0, y: 0, width: 32, height: 16), enabled: state.layerEnabled)
        session.document?.layers[0].gifFrameMasks[0] = try mask(revealing: CGRect(x: 0, y: 0, width: 16, height: 24), enabled: state.frameEnabled)
        session.document?.layers[0].gifFrameMasks[1] = try mask(enabled: state.frameEnabled)
        let snapshot = try #require(session.projectSnapshot())
        let document = session.document, undoCount = session.history.undoCount
        let editor = try await ImageExporter.shared.render(snapshot)
        #expect(try pixel(editor.image, x: 24, y: 12)[3] == (state.frameEnabled ? 0 : 255))
        #expect(try pixel(editor.image, x: 8, y: 20)[3] == (state.layerEnabled ? 0 : 255))

        let still = try await ImageExporter.shared.pngData(snapshot)
        let stillReader = try #require(CGImageSourceCreateWithData(still as CFData, nil))
        let stillPreview = try #require(CGImageSourceCreateImageAtIndex(stillReader, 0, nil))
        #expect(try pixel(stillPreview, x: 8, y: 12)[3] == 255)
        #expect(try pixel(stillPreview, x: 24, y: 12)[3] == (state.frameEnabled ? 0 : 255))
        #expect(try pixel(stillPreview, x: 8, y: 20)[3] == (state.layerEnabled ? 0 : 255))

        for all in [false, true] {
            let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24,
                options: GIFExportOptions(layerID: all ? nil : id))
            let reader = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
            #expect(CGImageSourceGetCount(reader) == session.gifTimelineFrames.count)
            #expect(try pixel(result.preview, x: 8, y: 12)[3] == 255)
            #expect(try pixel(result.preview, x: 24, y: 12)[3] == (state.frameEnabled ? 0 : 255))
            #expect(try pixel(result.preview, x: 8, y: 20)[3] == (state.layerEnabled ? 0 : 255))
            let nextPreview = try await GIFExporter.shared.preview(result.data, index: 1)
            #expect(try pixel(nextPreview, x: 8, y: 12)[3] == (state.frameEnabled ? 0 : 255))
            for index in 0..<CGImageSourceGetCount(reader) {
                let image = try #require(CGImageSourceCreateImageAtIndex(reader, index, nil))
                let frameHides = index == 1 && state.frameEnabled
                #expect(try pixel(image, x: 8, y: 20)[3] == (state.layerEnabled || frameHides ? 0 : 255))
                #expect(try pixel(image, x: 8, y: 12)[3] == (frameHides ? 0 : 255))
            }
        }
        #expect(session.document == document && session.history.undoCount == undoCount)
        #expect(session.gifTimelineSelectedFrameIndex == 0)
        #expect(session.activeLayer?.mask?.isEnabled == state.layerEnabled)
        #expect(session.activeLayer?.gifFrameMasks[0]?.isEnabled == state.frameEnabled)
        #expect(session.activeLayer?.gifFrameMasks[1]?.isEnabled == state.frameEnabled)
        #expect(snapshot.manifest.layers[0].maskEnabled == state.layerEnabled)
        #expect(snapshot.frameMasks[id]?.values.allSatisfy { $0.isEnabled == state.frameEnabled } == true)
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: package)
        let loaded = try await ProjectStore.shared.load(from: package)
        #expect(loaded.manifest.layers[0].maskEnabled == state.layerEnabled)
        #expect(loaded.frameMasks[id]?.values.allSatisfy { $0.isEnabled == state.frameEnabled } == true)
    }

    @Test(arguments: [false, true])
    func individualExportRespectsMaskVisibilityOnOtherCapturedTimelines(enabled: Bool) async throws {
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
        session.document?.layers[1].gifFrameMasks[1] = try mask(enabled: enabled)
        let snapshot = try #require(session.projectSnapshot())
        let result = try await GIFExporter.shared.encode(snapshot, width: 32, height: 24,
            options: GIFExportOptions(layerID: first))
        let reader = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        for index in 0..<CGImageSourceGetCount(reader) {
            let image = try #require(CGImageSourceCreateImageAtIndex(reader, index, nil))
            #expect(try pixel(image, x: 8, y: 12)[3] == 255)
            #expect(try pixel(image, x: 24, y: 12)[3] == (enabled ? 0 : 255))
        }
        #expect(session.activeLayerID == second && session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.activeLayer?.gifFrameMasks[1]?.isEnabled == enabled)
    }


}
