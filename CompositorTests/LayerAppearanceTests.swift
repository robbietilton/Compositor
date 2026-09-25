import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerAppearanceTests {
    @Test func hoverPreviewIsTemporaryAndNeverChangesSavedState() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.insert(try asset(0.8))
        session.history.markSaved()
        let id = try #require(session.activeLayerID)
        let count = session.history.undoCount
        for mode in LayerBlendMode.allCases {
            session.previewBlendMode(mode, for: id)
            #expect(session.displayedBlendMode(for: try #require(session.activeLayer)) == mode)
            #expect(session.activeLayer?.blendMode == .normal)
            #expect(session.projectSnapshot()?.manifest.layers.last?.blendMode == .normal)
            #expect(!session.isModified && session.history.undoCount == count)
        }
        session.previewBlendMode(nil, for: nil)
        #expect(session.displayedBlendMode(for: try #require(session.activeLayer)) == .normal)
        session.previewBlendMode(.multiply, for: id)
        session.setLayerBlendMode(.multiply)
        #expect(session.blendPreview == nil)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.activeLayer?.blendMode == .normal && !session.isModified)
    }
    @Test func moveToolNumberKeysSetSelectedLayersOpacityAsOneUndo() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.insert(try asset(0.2))
        let first = try #require(session.activeLayerID)
        session.insert(try asset(0.8))
        let second = try #require(session.activeLayerID)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.selectTool(.move)
        session.selectLayers([first, second, folder], primary: second)
        let count = session.history.undoCount
        session.typeOpacityDigit(5, at: 10)
        let layers = try #require(session.document?.layers)
        #expect(layers.filter { [first, second].contains($0.id) }.allSatisfy { $0.opacity == 0.5 })
        // Folders took an opacity of their own in 1.1.6, so a selected folder takes the typed value too.
        #expect(layers.first { $0.id == folder }?.opacity == 0.5)
        #expect(session.history.undoCount == count + 1)
        session.typeOpacityDigit(0, at: 20)
        #expect(session.document?.layers.first { $0.id == first }?.opacity == 1)
        session.undo()
        #expect(session.document?.layers.first { $0.id == first }?.opacity == 0.5)
        session.selectTool(.brush)
        session.typeOpacityDigit(3, at: 30)
        #expect(session.document?.layers.first { $0.id == second }?.opacity == 0.5)
    }
    private func asset(_ gray: CGFloat) throws -> ImportedImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Gray")
    }
    private func pixel(_ image: CGImage) throws -> (Double, Double) {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (Double(bytes[0]) / 255, Double(bytes[3]) / 255)
    }
    @Test func blendModesAndOpacityMatchKnownPixels() async throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.insert(try asset(0.4))
        session.insert(try asset(0.8))
        for (mode, expected) in [(LayerBlendMode.normal, 0.8), (.multiply, 0.32), (.screen, 0.88),
                                 (.overlay, 0.64), (.darken, 0.4), (.lighten, 0.8), (.difference, 0.4),
                                 (.colorDodge, 1), (.colorBurn, 0.25)] {
            session.setLayerBlendMode(mode)
            #expect(try JSONDecoder().decode(LayerBlendMode.self, from: JSONEncoder().encode(mode)) == mode)
            let raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
            let (value, alpha) = try pixel(raster.image)
            #expect(abs(value - expected) < 0.02, "\(mode.rawValue): \(value), expected \(expected)")
            #expect(alpha == 1)
        }
        session.setLayerBlendMode(.normal)
        session.setLayerOpacity(0.5)
        let half = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(abs(try pixel(half.image).0 - 0.6) < 0.02)
        session.setLayerOpacity(0)
        let hidden = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(abs(try pixel(hidden.image).0 - 0.4) < 0.02)
    }
    @Test func opacityDragIsOneUndoAndKeepsSources() throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        let source = try asset(0.8)
        session.insert(source)
        let count = session.history.undoCount
        session.beginOpacityEdit()
        for value in stride(from: 9, through: 2, by: -1) { session.setLayerOpacity(Double(value) / 10) }
        session.finishOpacityEdit()
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.asset?.image === source.image)
        session.undo()
        #expect(session.activeLayer?.opacity == 1)
        session.redo()
        #expect(abs((session.activeLayer?.opacity ?? 1) - 0.2) < 0.001)
    }
    @Test func appearancePersistsThroughSaveResizeAndTransparentExport() async throws {
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.addGroup()
        session.insert(try asset(0.8))
        let id = try #require(session.activeLayerID)
        session.setLayerOpacity(0.25)
        session.setLayerBlendMode(.multiply)
        let snapshot = try #require(session.projectSnapshot())
        let raster = try await ImageExporter.shared.render(snapshot)
        #expect(abs(try pixel(raster.image).1 - 0.25) < 0.01)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Appearance-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 9)
        let resized = try await ImageResizer.shared.resize(loaded, to: ImageSizeOptions(width: 8, height: 8, resolution: 72))
        let canvas = try await CanvasResizer.shared.resize(resized, to: CanvasSizeOptions(width: 12, height: 12))
        let record = try #require(canvas.manifest.layers.first { $0.id == id })
        #expect(record.opacity == 0.25 && record.blendMode == .multiply)
        #expect(record.parentID != nil)
    }
}
