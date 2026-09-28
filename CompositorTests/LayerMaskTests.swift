import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct LayerMaskTests {
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 2, height: 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.document?.layers[0].transform.sampling = .nearest
        return session
    }
    private func coverage() throws -> LayerMask {
        let provider = try #require(CGDataProvider(data: Data([255, 0, 128, 255]) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return LayerMask(asset: try LayerMask.asset(from: image))
    }
    private func alphas(_ image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { Int(bytes[$0 * 4 + 3]) }
    }
    @Test func addDisableDeleteUndoAndTargetSelection() throws {
        let session = try session()
        let original = try #require(session.activeLayer?.asset?.image)
        let count = session.history.undoCount
        session.addLayerMask(revealing: false)
        #expect(session.isMaskSelected && session.activeLayer?.mask != nil)
        #expect(session.activeLayer?.mask?.asset.image.width == 1)
        #expect(session.history.undoCount == count + 1)
        session.addLayerMask() // Do not overwrite an existing mask.
        #expect(session.history.undoCount == count + 1)
        session.toggleLayerMask()
        #expect(session.activeLayer?.mask?.isEnabled == false)
        session.deleteLayerMask()
        #expect(session.activeLayer?.mask == nil && !session.isMaskSelected)
        session.undo()
        #expect(session.activeLayer?.mask?.isEnabled == false)
        session.undo()
        #expect(session.activeLayer?.mask?.isEnabled == true)
        session.undo()
        #expect(session.activeLayer?.mask == nil)
        session.redo()
        let id = try #require(session.activeLayerID)
        session.selectLayerTarget(id, mask: true)
        #expect(session.isMaskSelected)
        session.selectLayerTarget(id, mask: false)
        #expect(!session.isMaskSelected && session.activeLayer?.asset?.image === original)
        session.addGroup()
        session.addLayerMask()
        #expect(session.activeLayer?.isGroup == true && session.activeLayer?.mask != nil)
    }
    @Test func coverageOpacityAndDisabledMasksRenderCorrectly() async throws {
        let session = try session()
        session.addLayerMask()
        var raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try alphas(raster.image) == [255, 255, 255, 255])
        session.deleteLayerMask()
        session.addLayerMask(revealing: false)
        raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try alphas(raster.image) == [0, 0, 0, 0])
        session.toggleLayerMask()
        raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try alphas(raster.image) == [255, 255, 255, 255])
        session.document?.layers[0].mask = try coverage()
        raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try alphas(raster.image) == [255, 0, 128, 255])
        session.setLayerOpacity(0.5)
        raster = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        let values = try alphas(raster.image)
        #expect(zip(values, [128, 0, 64, 128]).allSatisfy { abs($0 - $1) <= 1 })
    }
    @Test func transformedMaskResizeAndCanvasChangesStayAligned() async throws {
        let session = try session()
        session.document?.layers[0].mask = try coverage()
        session.document?.layers[0].transform.flipX = true
        let input = try #require(session.projectSnapshot())
        let flipped = try await ImageExporter.shared.render(input)
        #expect(try alphas(flipped.image) == [0, 255, 255, 128])
        let resized = try await ImageResizer.shared.resize(input,
            to: ImageSizeOptions(width: 4, height: 4, resolution: 72, sampling: .nearest))
        let raster = try await ImageExporter.shared.render(resized)
        let scaledValues = try alphas(raster.image)
        #expect(scaledValues == [0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 128, 128, 255, 255, 128, 128])
        let canvas = try await CanvasResizer.shared.resize(resized, to: CanvasSizeOptions(width: 6, height: 6))
        let id = try #require(session.activeLayerID)
        #expect(canvas.masks[id]?.image === resized.masks[id]?.image)
        session.applyDocumentSize(canvas, actionName: "Canvas Size")
        #expect(session.activeLayer?.mask != nil)
        session.undo()
        #expect(session.document?.width == 2 && session.activeLayer?.mask?.asset.image.width == 2)
        // Rotation uses the same local coverage as image pixels; total covered area is unchanged.
        session.document?.layers[0].transform.rotation = 90
        let rotated = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try alphas(rotated.image).sorted() == [0, 128, 255, 255])
    }
    @Test func projectAndPNGPreserveCoverageAndDisabledState() async throws {
        let session = try session()
        session.document?.layers[0].mask = try coverage()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Masks-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        for enabled in [true, false] {
            session.document?.layers[0].mask?.isEnabled = enabled
            try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
            let loaded = try await ProjectStore.shared.load(from: url)
            #expect(loaded.manifest.version == 11)
            session.installProject(loaded, from: url)
            #expect(session.activeLayer?.mask?.isEnabled == enabled)
            let png = try await ImageExporter.shared.pngData(loaded)
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(try alphas(image) == (enabled ? [255, 0, 128, 255] : [255, 255, 255, 255]))
        }
        // Missing mask assets must fail instead of silently revealing the image.
        let record = try #require(session.projectSnapshot()?.manifest.layers.first)
        try FileManager.default.removeItem(at: url.appendingPathComponent("images").appendingPathComponent(try #require(record.maskFile)))
        await #expect(throws: (any Error).self) { try await ProjectStore.shared.load(from: url) }
    }
    @Test func masksRejectOlderSchemaAndUnsafePaths() async throws {
        let session = try session()
        session.addLayerMask()
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InvalidMask-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        var old = snapshot.manifest
        old.version = 3
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: old, images: snapshot.images, masks: snapshot.masks), to: url)
        }
        old.version = 4
        old.layers[0].maskFile = "../outside.png"
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: old, images: snapshot.images, masks: snapshot.masks), to: url)
        }
    }

    /// The Red layer inside a folder, with nearest sampling so 2 × 2 masks map pixel for pixel.
    private func folderSession() throws -> (session: EditorSession, folder: UUID, red: UUID) {
        let session = try session()
        let red = try #require(session.activeLayerID)
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == folder })
        session.document?.layers[index].transform.sampling = .nearest
        return (session, folder, red)
    }
    /// Export and the canvas's own composite (used for sampling and Copy Merged) must agree.
    private func renderBoth(_ session: EditorSession) async throws -> [Int] {
        let exported = try alphas(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        let context = try BrushRaster.context(width: 2, height: 2, mask: false)
        session.drawLiveComposite(try #require(session.document), in: context)
        #expect(try alphas(try #require(context.makeImage())) == exported)
        return exported
    }
    @Test func folderMasksClipEveryLayerInsideAndMultiplyWithTheirOwnMasks() async throws {
        let (session, folder, red) = try folderSession()
        #expect(session.activeLayer?.isGroup == true && session.canEditMask)
        let count = session.history.undoCount
        session.addLayerMask(revealing: false)
        #expect(session.isMaskSelected && session.activeLayer?.mask != nil)
        #expect(session.history.undoCount == count + 1)
        #expect(try await renderBoth(session) == [0, 0, 0, 0])
        session.toggleLayerMask()
        #expect(try await renderBoth(session) == [255, 255, 255, 255])
        session.toggleLayerMask()
        // Soft folder coverage, then multiplied with the layer's own soft mask.
        let folderIndex = try #require(session.document?.layers.firstIndex { $0.id == folder })
        let redIndex = try #require(session.document?.layers.firstIndex { $0.id == red })
        session.document?.layers[folderIndex].mask = try coverage()
        #expect(try await renderBoth(session) == [255, 0, 128, 255])
        session.document?.layers[redIndex].mask = try coverage()
        let combined = try await renderBoth(session)
        #expect(zip(combined, [255, 0, 64, 255]).allSatisfy { abs($0 - $1) <= 1 })
        // An enclosing folder's mask applies as well.
        session.document?.layers[redIndex].mask = nil
        session.selectLayer(folder)
        session.groupSelectedLayers()
        #expect(session.activeLayerID != folder && session.activeLayer?.isGroup == true)
        session.addLayerMask(revealing: false)
        #expect(try await renderBoth(session) == [0, 0, 0, 0])
        session.deleteLayerMask()
        #expect(try await renderBoth(session) == [255, 0, 128, 255])
        session.undo()
        #expect(try await renderBoth(session) == [0, 0, 0, 0])
    }
    @Test func folderMaskCanBePaintedInvertedAndLoadedAsASelection() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 160, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.addLayerMask()
        #expect(session.canPaint && session.canInvert && session.canCopyPixels)
        // Painting black on the folder's mask hides the layer inside only there.
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 8, hardness: 1, red: 0, green: 0, blue: 0)
        session.maskPaintWhite = false
        session.beginBrush(at: CGPoint(x: 10, y: 10))
        session.continueBrush(at: CGPoint(x: 11, y: 10))
        await session.finishBrush()
        var values = try alphas(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(values[10 * 40 + 10] == 0 && values[10 * 40 + 30] == 255)
        #expect(session.activeLayerID == folder && session.isMaskSelected)
        // Invert swaps what the folder hides.
        await session.invertPixels()
        values = try alphas(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        #expect(values[10 * 40 + 10] == 255 && values[10 * 40 + 30] == 0)
        // Cmd-click on the folder's mask thumbnail selects its black areas.
        session.loadMaskSelection(layerID: folder)
        #expect((session.selection?.path.boundingBoxOfPath.width ?? 0) > 30)
        // Selecting the folder's pixels (it has none) still paints nothing.
        session.selectLayerTarget(folder, mask: false)
        #expect(!session.canPaint && !session.canInvert && !session.canCopyPixels)
    }
    /// A folder's mask only exists as tiles until the stroke ends; the canvas must still show
    /// it, on both the scaled (zoomed-out) and crisp (zoomed-in) drawing paths.
    @Test func canvasShowsAFolderMaskWhileItIsBeingPainted() throws {
        let size = CGSize(width: 200, height: 100)
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 800, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        session.groupSelectedLayers()
        session.addLayerMask()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 30, hardness: 1, red: 0, green: 0, blue: 0)
        session.maskPaintWhite = false
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: size)
        func color(at point: CGPoint) throws -> (red: CGFloat, green: CGFloat) {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let spot = session.viewport.viewPoint(from: point, documentSize: size)
            let pixel = try #require(rep.colorAt(x: Int(spot.x * scale), y: Int(spot.y * scale))?.usingColorSpace(.sRGB))
            return (pixel.redComponent, pixel.greenComponent)
        }
        for zoom in [1.0, 3.0] {
            session.viewport.setZoom(zoom, anchoredAt: session.viewport.center, documentSize: size)
            // Compared with the same spot before painting, whatever color space the view renders in.
            let layer = try color(at: CGPoint(x: 140, y: 50))
            #expect(layer.red - layer.green > 0.5, "zoom \(zoom): the layer reads as \(layer)")
            session.beginBrush(at: CGPoint(x: 100, y: 50))
            session.continueBrush(at: CGPoint(x: 101, y: 50))
            #expect(session.brushStroke != nil)
            let hidden = try color(at: CGPoint(x: 100, y: 50))
            let shown = try color(at: CGPoint(x: 140, y: 50))
            // Hidden shows the neutral checkerboard behind; shown is still the red layer.
            #expect(abs(hidden.red - hidden.green) < 0.1, "zoom \(zoom): painted area shows \(hidden), not the checkerboard")
            #expect(abs(shown.red - layer.red) < 0.02 && abs(shown.green - layer.green) < 0.02,
                    "zoom \(zoom): unpainted area changed from \(layer) to \(shown)")
            session.cancelBrush()
        }
        window.orderOut(nil)
    }
    @Test func applyLayerMaskBakesAtNativeResolutionNotDocumentSizeAndUndoes() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        // A 1000 × 1000 native asset, placed on the document scaled down to 10% (100 × 100) — applying must not
        // resample it down to the document's own size.
        let native = 1000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let pixels = try #require(CGContext(data: nil, width: native, height: native, bitsPerComponent: 8,
            bytesPerRow: native * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        pixels.fill(CGRect(x: 0, y: 0, width: native, height: native))
        let original = try #require(pixels.makeImage())
        session.insert(ImportedImage(image: original, thumbnail: original, name: "Big"))
        let id = try #require(session.activeLayerID)
        session.document?.layers[0].transform.size = CGSize(width: 100, height: 100)
        session.document?.layers[0].transform.sampling = .nearest

        // A mask that covers the layer's own grid (`placement == nil`), left half reveal, right half hide.
        let maskProvider = try #require(CGDataProvider(data: Data([255, 0]) as CFData))
        let maskImage = try #require(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: maskProvider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: maskImage))
        #expect(session.canApplyLayerMask)

        let undoCount = session.history.undoCount
        session.applyLayerMask()
        let layer = try #require(session.activeLayer)
        #expect(layer.id == id)
        #expect(layer.mask == nil)
        #expect(layer.asset?.image.width == native && layer.asset?.image.height == native,
                "the asset keeps its full native resolution")
        #expect(layer.transform.size == CGSize(width: 100, height: 100), "the on-canvas placement is untouched")
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Apply Layer Mask")

        // Sampled coarsely: the left half stays opaque, the right half — where the mask was black — is transparent.
        let baked = try #require(layer.asset?.image)
        let grid = 4
        let context = try #require(CGContext(data: nil, width: grid, height: grid, bitsPerComponent: 8,
            bytesPerRow: grid * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(baked, in: CGRect(x: 0, y: 0, width: grid, height: grid))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for row in 0..<grid {
            #expect(bytes[(row * grid + 0) * 4 + 3] > 200, "row \(row): left stays visible")
            #expect(bytes[(row * grid + grid - 1) * 4 + 3] < 50, "row \(row): right is hidden")
        }

        session.undo()
        #expect(session.activeLayer?.mask != nil)
        #expect(session.activeLayer?.asset?.image === original, "undo restores the original asset object")
    }

    @Test func applyLayerMaskRendersAMovedMaskThroughItsOwnPlacement() throws {
        let session = try session()
        // Move the mask apart from the layer, covering only its left half; the rest falls back to the mask's
        // own background (its thumbnail's edge color).
        var mask = try coverage()
        mask.placement = LayerTransform(origin: .zero, size: CGSize(width: 1, height: 2))
        session.document?.layers[0].mask = mask
        #expect(session.canApplyLayerMask)
        session.applyLayerMask()
        let layer = try #require(session.activeLayer)
        #expect(layer.mask == nil)
        #expect(layer.asset?.image.width == 2 && layer.asset?.image.height == 2, "still the layer's own 2 × 2 grid")
        #expect(try alphas(try #require(layer.asset?.image)) != [255, 255, 255, 255], "the moved mask actually changed something")
    }

    @Test func applyLayerMaskIsUnavailableForGroupsAdjustmentsLiveTextAndDisabledMasks() throws {
        let session = try session()
        #expect(!session.canApplyLayerMask, "no mask yet")
        session.addLayerMask()
        #expect(session.canApplyLayerMask)
        session.toggleLayerMask()
        #expect(!session.canApplyLayerMask, "Photoshop asks before applying a disabled mask; here it's just left off")
        session.toggleLayerMask()
        #expect(session.canApplyLayerMask)

        session.addGroup()
        session.addLayerMask()
        #expect(session.activeLayer?.isGroup == true && session.activeLayer?.mask != nil)
        #expect(!session.canApplyLayerMask, "a folder has no pixels of its own to bake into")

        session.addAdjustment(.invert)
        session.addLayerMask()
        #expect(session.activeLayer?.adjustment != nil && session.activeLayer?.mask != nil)
        #expect(!session.canApplyLayerMask, "an adjustment layer has no pixels of its own either")

        session.createDocument(width: 400, height: 300, emptyLayer: true)
        session.selectTool(.type)
        session.beginText(at: CGPoint(x: 20, y: 20))
        session.textDraft?.style.content = "Text"
        #expect(session.applyText(try #require(session.textDraft)))
        #expect(session.activeLayer?.liveText != nil)
        session.addLayerMask()
        #expect(!session.canApplyLayerMask, "still live text — baking would throw away its editable source")
    }

    @Test func folderMasksSaveResizeAndNeedTheNewFormat() async throws {
        let (session, folder, _) = try folderSession()
        let folderIndex = try #require(session.document?.layers.firstIndex { $0.id == folder })
        session.document?.layers[folderIndex].mask = try coverage()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderMask-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 11 && loaded.masks[folder] != nil)
        #expect(try alphas(try await ImageExporter.shared.render(loaded).image) == [255, 0, 128, 255])
        let resized = try await ImageResizer.shared.resize(loaded,
            to: ImageSizeOptions(width: 4, height: 4, resolution: 72, sampling: .nearest))
        #expect(try alphas(try await ImageExporter.shared.render(resized).image)
            == [255, 255, 0, 0, 255, 255, 0, 0, 128, 128, 255, 255, 128, 128, 255, 255])
        // Earlier formats never had folder masks, so a file claiming one is refused.
        var old = snapshot.manifest
        old.version = 5
        await #expect(throws: ProjectError.self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: old, images: snapshot.images, masks: snapshot.masks), to: url)
        }
    }
}
