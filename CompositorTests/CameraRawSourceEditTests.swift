import AppKit
import Testing
@testable import Compositor

@MainActor
struct CameraRawSourceEditTests {
    private func session() throws -> EditorSession {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 8, height: 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Source"))
        var settings = CameraRawSettings()
        settings.exposure = 1
        session.document?.layers[0].cameraRawOperation = CameraRawOperation(payload: try JSONEncoder().encode(settings))
        return session
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * image.height)
    }

    @Test func pixelToolsRefuseButPlacementAndPluginRemainAvailable() throws {
        let session = try session()
        let source = try #require(session.activeLayer?.asset?.image)
        #expect(!session.canPaint && !session.canAdjustColors && !session.canInvert && !session.canConvertLayerDepth)
        #expect(session.canTransform && session.canEditCameraRawPlugin)
        session.beginFilter(.cameraRaw)
        #expect(session.filterEdit == nil)
        #expect(session.activeLayer?.asset?.image === source)
        #expect(session.paintRefusal != nil)
    }

    @Test func duplicateKeepsSourceAndOpaqueRecipe() throws {
        let session = try session()
        let original = try #require(session.activeLayer)
        session.document?.layers[0].cameraRawOperation = CameraRawOperation(payload: Data([0, 1, 2]), schemaVersion: 9)
        let operation = session.activeLayer?.cameraRawOperation
        session.duplicateActiveLayer()
        #expect(session.document?.layers.count == 2)
        #expect(session.activeLayer?.id != original.id)
        #expect(session.activeLayer?.asset?.image === original.asset?.image)
        #expect(session.activeLayer?.cameraRawOperation == operation)
    }

    @Test func canvasResizeKeepsRecipeAndImageResizeRefusesRebase() async throws {
        let session = try session()
        let snapshot = try #require(session.projectSnapshot())
        let resized = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(width: 12, height: 12))
        #expect(resized.manifest.layers[0].cameraRawOperation == snapshot.manifest.layers[0].cameraRawOperation)
        #expect(resized.images[snapshot.manifest.layers[0].id]?.image === snapshot.images[snapshot.manifest.layers[0].id]?.image)
        await #expect(throws: CameraRawSourceEditError.self) {
            try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(width: 12, height: 12, resolution: 72))
        }
        let metadataOnly = try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(width: 8, height: 8, resolution: 300))
        #expect(metadataOnly.manifest.layers[0].cameraRawOperation == snapshot.manifest.layers[0].cameraRawOperation)
    }

    @Test func copiedPixelsAndMergedPixelsUseGradeAndRejectUnavailableRecipe() throws {
        let session = try session()
        let layer = try #require(session.activeLayer)
        let image = try #require(session.renderSelectedPixels(from: layer, mask: false)?.image)
        let reference = try CameraRawOperationRenderer.shared.render(#require(layer.asset), operation: #require(layer.cameraRawOperation))
        #expect(try pixels(image) == pixels(reference.image))
        #expect(try pixels(image) != pixels(#require(layer.asset?.image)))
        session.document?.layers[0].cameraRawOperation = CameraRawOperation(payload: Data([1]), schemaVersion: 9)
        #expect(throws: CameraRawOperationRenderError.self) {
            try session.renderSelectedPixels(from: #require(session.activeLayer), mask: false)
        }
        #expect(throws: CameraRawOperationRenderError.self) { try session.renderMergedPixels() }
    }

    @Test func selectionAndCloneSamplingUseGradeAndCloneRejectsUnavailableRecipe() throws {
        let session = try session()
        let layer = try #require(session.activeLayer)
        let document = try #require(session.document)
        let reference = try CameraRawOperationRenderer.shared.render(#require(layer.asset), operation: #require(layer.cameraRawOperation))
        let selected = try #require(session.selectionSample(document, sampleAllLayers: false))
        #expect(try pixels(selected) == pixels(reference.image))
        var target = layer
        target.cameraRawOperation = nil
        let stroke = try session.makeRasterEdit(for: target)
        session.cloneSettings.sampleAllLayers = true
        let sample = try #require(try session.cloneSample(document, for: stroke, offset: .zero))
        #expect(try pixels(sample.image) == pixels(reference.image))
        var unavailable = document
        unavailable.layers[0].cameraRawOperation = CameraRawOperation(payload: Data([1]), schemaVersion: 9)
        #expect(throws: CameraRawOperationRenderError.self) {
            try session.cloneSample(unavailable, for: stroke, offset: .zero)
        }
    }

    @Test func floatingMergeCannotBakeBehindAnOperation() throws {
        let session = try session()
        let layer = try #require(session.activeLayer)
        #expect(throws: CameraRawSourceEditError.self) {
            try FloatingMerge.merge(#require(layer.asset?.image), transform: layer.transform, into: layer)
        }
    }
}
