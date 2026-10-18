import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor
struct CameraRawOperationRenderTests {
    private func asset() throws -> ImportedImage {
        let context = try BrushRaster.context(width: 24, height: 16, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.35, blue: 0.25, alpha: 0.8))
        context.fill(CGRect(x: 2, y: 2, width: 20, height: 12))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Source")
    }

    private func operation(seed: UInt32 = 42) throws -> CameraRawOperation {
        var settings = CameraRawSettings()
        settings.exposure = 0.75
        settings.temperature = 20
        settings.grainAmount = 25
        return CameraRawOperation(payload: try JSONEncoder().encode(settings), seed: seed)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try BrushRaster.copy(image)
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }

    private func deepPixels(_ image: CGImage) throws -> Data {
        let context = try DeepLayer.isHDR(image) ? DeepLayer.hdr(image) : DeepLayer.canonical(image)
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }

    private func snapshot(_ source: ImportedImage, operation: CameraRawOperation?, effects: LayerEffects? = nil) -> ProjectSnapshot {
        let id = UUID()
        var layer = ProjectLayerRecord(id: id, name: source.name, isVisible: true,
            transform: LayerTransform(origin: CGPoint(x: 3, y: 4), size: CGSize(width: source.image.width, height: source.image.height)),
            imageFile: "\(id).png")
        layer.cameraRawOperation = operation
        layer.effects = effects
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 32, height: 24,
            activeLayerID: id, layers: [layer]), images: [id: source])
    }

    @Test func identityPreservesTheEntireSourceAsset() throws {
        var source = try asset()
        source.deep = try DeepLayer.image(source.image)
        let raster = RasterSnapshot(width: 24, height: 16, base: source.image,
            baseRect: CGRect(x: 0, y: 0, width: 24, height: 16), patches: [])
        source.raster = raster
        let identity = CameraRawOperation(payload: try JSONEncoder().encode(CameraRawSettings()))
        let result = try CameraRawOperationRenderer().render(source, operation: identity)
        #expect(result.image === source.image && result.thumbnail === source.thumbnail)
        #expect(result.deep === source.deep && result.raster === raster)
        #expect(!raster.hasMaterializedPixels)
    }

    @Test func hostRenderingMatchesCPUSettingsAndNeverChangesTheSource() throws {
        let source = try asset(), operation = try operation()
        let before = try pixels(source.image)
        let renderer = CameraRawOperationRenderer()
        let result = try renderer.render(source, operation: operation)
        let settings = try #require(operation.settings)
        let expected = try settings.apply(source.image, seed: operation.seed, usesGPU: false)
        #expect(try pixels(result.image) == pixels(expected))
        #expect(try pixels(result.image) != before)
        #expect(try pixels(source.image) == before)
        #expect(result.raster == nil && result.deep == nil)
        #expect(result.name == source.name)
        #expect(try renderer.render(source, operation: operation).image === result.image)
    }

    @Test func cacheIncludesSeedAndEvictsOldDerivedAssets() throws {
        let source = try asset(), renderer = CameraRawOperationRenderer()
        let first = try renderer.render(source, operation: operation(seed: 1))
        let second = try renderer.render(source, operation: operation(seed: 2))
        #expect(first.image !== second.image)
        #expect(try pixels(first.image) != pixels(second.image))
        for seed: UInt32 in [3, 4, 5] { _ = try renderer.render(source, operation: operation(seed: seed)) }
        let rebuilt = try renderer.render(source, operation: operation(seed: 1))
        #expect(rebuilt.image !== first.image, "the cache retains at most four source/operation pairs")
        #expect(try pixels(rebuilt.image) == pixels(first.image), "grain stays fixed even after eviction")
    }

    @Test func concurrentRequestsShareOneStableDerivedImage() async throws {
        let source = try asset(), operation = try operation(), renderer = CameraRawOperationRenderer()
        let results = try await withThrowingTaskGroup(of: ImportedImage.self) { group in
            for _ in 0..<8 { group.addTask { try renderer.render(source, operation: operation) } }
            var results: [ImportedImage] = []
            for try await result in group { results.append(result) }
            return results
        }
        let first = try #require(results.first)
        #expect(results.allSatisfy { $0.image === first.image })
    }

    @Test func geometryIncludingConstrainCropKeepsTheSourceGrid() throws {
        let source = try asset()
        for constrain in [false, true] {
            var settings = CameraRawSettings()
            settings.geometry.rotate = 17
            settings.geometry.offsetX = 20
            settings.geometry.constrainCrop = constrain
            let operation = CameraRawOperation(payload: try JSONEncoder().encode(settings))
            let result = try CameraRawOperationRenderer().render(source, operation: operation)
            #expect(result.image.width == source.image.width && result.image.height == source.image.height)
            let direct = try settings.apply(source.image, usesGPU: false)
            #expect(try pixels(result.image) == pixels(direct))
        }
    }

    @Test func deepAndHDRRenderingUseTheFullDepthSource() throws {
        let operation = try operation()
        let settings = try #require(operation.settings)
        for hdr in [false, true] {
            let context = try DeepLayer.context(width: 24, height: 16, hdr: hdr)
            let data = try #require(context.data).assumingMemoryBound(to: UInt16.self)
            for index in 0..<(24 * 16) {
                let value = hdr ? Float16(1.5 + Double(index % 24) / 48).bitPattern : UInt16(20_000 + index % 24 * 23)
                data[index * 4] = value
                data[index * 4 + 1] = value
                data[index * 4 + 2] = value
                data[index * 4 + 3] = hdr ? Float16(1).bitPattern : UInt16.max
            }
            let deep = try #require(context.makeImage())
            var source = try DeepLayer.asset(deep, name: "Deep")
            // A painted deep layer keeps its original deep base plus newer 8-bit replacement patches.
            let patch = try #require(asset().image.cropping(to: CGRect(x: 2, y: 2, width: 4, height: 4)))
            let raster = RasterSnapshot(width: 24, height: 16, base: source.image,
                baseRect: CGRect(x: 0, y: 0, width: 24, height: 16),
                patches: [BrushPatch(rect: CGRect(x: 5, y: 5, width: 4, height: 4), image: patch)])
            source = ImportedImage(image: try raster.makeImage(), thumbnail: source.thumbnail, name: source.name,
                                   raster: raster, deep: source.deep)
            let before = try deepPixels(try #require(source.deep))
            let result = try CameraRawOperationRenderer().render(source, operation: operation)
            let full = try #require(result.deep)
            let expected = try DeepLayer.run(try #require(try DeepLayer.flattened(source)), mixesChannels: true) {
                try settings.apply($0, seed: operation.seed, usesGPU: false)
            }
            #expect(full.bitsPerComponent == 16)
            #expect(DeepLayer.isHDR(full) == hdr)
            #expect(try deepPixels(full) == deepPixels(expected))
            #expect(try deepPixels(try #require(source.deep)) == before)
        }
    }

    @Test func sparseSourceIsRenderedInsteadOfBypassed() throws {
        let base = try asset()
        let patch = try BrushRaster.context(width: 4, height: 4, mask: false)
        patch.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        patch.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let raster = RasterSnapshot(width: 24, height: 16, base: base.image,
            baseRect: CGRect(x: 0, y: 0, width: 24, height: 16),
            patches: [BrushPatch(rect: CGRect(x: 5, y: 5, width: 4, height: 4), image: try #require(patch.makeImage()))])
        let source = ImportedImage(image: try raster.makeImage(), thumbnail: base.thumbnail, name: base.name, raster: raster)
        let operation = try operation(), settings = try #require(operation.settings)
        let expected = try settings.apply(source.image, seed: operation.seed, usesGPU: false)
        let result = try CameraRawOperationRenderer().render(source, operation: operation)
        #expect(try pixels(result.image) == pixels(expected))
        #expect(result.raster == nil, "the original-raster canvas fast path cannot bypass the operation")
        #expect(source.raster === raster && raster.patches.count == 1)
    }

    @Test func exportAndNavigatorMatchABakedReferenceWithEffectsAfterTheOperation() async throws {
        let source = try asset(), operation = try operation()
        let derived = try CameraRawOperationRenderer.shared.render(source, operation: operation)
        let effects = LayerEffects(stroke: StrokeEffect(size: 2), shadow: ShadowEffect(distance: 2, blur: 1))
        let original = snapshot(source, operation: operation, effects: effects)
        let reference = snapshot(derived, operation: nil, effects: effects)
        for deep in [false, true] {
            let result = try await ImageExporter.shared.render(original, sixteenBit: deep)
            let baked = try await ImageExporter.shared.render(reference, sixteenBit: deep)
            #expect(try pixels(result.image) == pixels(baked.image))
        }
        #expect(original.images.values.first?.image === source.image)
        #expect(original.manifest.layers.first?.cameraRawOperation == operation)

        var layer = ImageLayer(asset: source, origin: .zero)
        layer.cameraRawOperation = operation
        layer.effects = effects
        let session = EditorSession()
        session.document = CanvasDocument(width: 24, height: 16, layers: [layer])
        let shown = try #require(session.navigatorImage(maxSide: 24))
        let rendered = try #require(session.document).renderedCameraRawOperations()
        session.document = rendered
        let baked = try #require(session.navigatorImage(maxSide: 24))
        #expect(try pixels(shown) == pixels(baked))
        #expect(rendered.layers[0].cameraRawOperation == nil)
        #expect(layer.asset?.image === source.image && layer.cameraRawOperation == operation)
    }

    @Test func canvasCPUAndGPUUseTheDerivedAssetAndRedrawOnOperationChanges() throws {
        let source = try asset(), operation = try operation()
        var layer = ImageLayer(asset: source, origin: .zero)
        layer.cameraRawOperation = operation
        let document = CanvasDocument(width: 24, height: 16, layers: [layer])
        let rendered = try document.renderedCameraRawOperations()
        func canvas(_ document: CanvasDocument) -> CanvasView {
            let session = EditorSession()
            session.document = document
            let view = CanvasView(session: session)
            view.frame = CGRect(x: 0, y: 0, width: 180, height: 120)
            session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: document.size)
            view.synchronizeDisplay()
            return view
        }
        func cpu(_ canvas: CanvasView) throws -> CGImage {
            let context = try BrushRaster.context(width: 180, height: 120, mask: false)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.allowsGPU = false
            canvas.draw(canvas.bounds)
            return try #require(context.makeImage())
        }
        let adjusted = canvas(document), baked = canvas(rendered)
        #expect(try pixels(cpu(adjusted)) == pixels(cpu(baked)))
        if let renderer = GPUCanvasRenderer.shared {
            let bounds = CGRect(x: 0, y: 0, width: 180, height: 120)
            let a = try #require(adjusted.gpuFrame(size: bounds.size))
            let b = try #require(baked.gpuFrame(size: bounds.size))
            let imageA = try #require(renderer.context.createCGImage(a, from: bounds, format: .RGBA8, colorSpace: renderer.space))
            let imageB = try #require(renderer.context.createCGImage(b, from: bounds, format: .RGBA8, colorSpace: renderer.space))
            #expect(try pixels(imageA) == pixels(imageB))
        }
        adjusted.session.document?.layers[0].cameraRawOperation = nil
        #expect(adjusted.synchronizeDisplay(), "operation changes redraw even when the original CGImage is unchanged")
    }

    @Test func liveMaskBakingRendersTargetAndDependenciesBeforeCommittingPixels() throws {
        let source = try asset(), operation = try operation()
        let original = snapshot(source, operation: operation)
        let target = try #require(original.manifest.layers.first)
        let baseID = UUID()
        var settings = CameraRawSettings()
        settings.geometry.offsetX = 25
        let baseOperation = CameraRawOperation(payload: try JSONEncoder().encode(settings))
        var base = ProjectLayerRecord(id: baseID, name: "Mask source", isVisible: true,
            transform: target.transform, imageFile: "\(baseID).png")
        base.cameraRawOperation = baseOperation
        var manifest = original.manifest
        manifest.layers[0].maskSourceID = baseID
        manifest.layers.insert(base, at: 0)
        let snapshot = ProjectSnapshot(manifest: manifest, images: [target.id: source, baseID: source])
        let baked = try #require(try LiveMaskBaker.bake(snapshot, target: target.id))
        var referenceManifest = manifest
        for index in referenceManifest.layers.indices { referenceManifest.layers[index].cameraRawOperation = nil }
        let reference = ProjectSnapshot(manifest: referenceManifest, images: [
            target.id: try CameraRawOperationRenderer.shared.render(source, operation: operation),
            baseID: try CameraRawOperationRenderer.shared.render(source, operation: baseOperation),
        ])
        let expected = try #require(try LiveMaskBaker.bake(reference, target: target.id))
        #expect(try pixels(baked.image) == pixels(expected.image))
        manifest.layers[0].cameraRawOperation = CameraRawOperation(payload: Data(), schemaVersion: 99)
        let unavailable = ProjectSnapshot(manifest: manifest, images: snapshot.images)
        #expect(throws: CameraRawOperationRenderError.self) { try LiveMaskBaker.bake(unavailable, target: target.id) }
        #expect(snapshot.images[target.id]?.image === source.image)
    }

    @Test func unavailableOperationsFallBackOnlyForDisplayAndFailExport() async throws {
        let source = try asset()
        for operation in [CameraRawOperation(payload: Data("{}".utf8), pluginID: "future.camera-raw"),
                          CameraRawOperation(payload: Data("{}".utf8), schemaVersion: 99),
                          CameraRawOperation(payload: Data("invalid".utf8))] {
            #expect(throws: CameraRawOperationRenderError.self) {
                try CameraRawOperationRenderer().render(source, operation: operation)
            }
            var layer = ImageLayer(asset: source, origin: .zero)
            layer.cameraRawOperation = operation
            #expect(layer.effectiveRenderAsset?.image === source.image)
            let document = CanvasDocument(width: 24, height: 16, layers: [layer])
            #expect(throws: CameraRawOperationRenderError.self) { try document.renderedCameraRawOperations() }
            await #expect(throws: CameraRawOperationRenderError.self) {
                try await ImageExporter.shared.render(snapshot(source, operation: operation))
            }
        }
    }
}
