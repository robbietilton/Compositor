import AppKit
import CoreImage
import Testing
@testable import Compositor

/// Progressive Blur, Bloom / Glow, RGB Split, Vignette, Lens Effects and Tonal Contrast as adjustment layers.
@MainActor
struct FilterLayerTests {
    /// A white square in the middle of a clear 61 × 61 image, rows top-down.
    private func square() throws -> CGImage {
        let context = try BrushRaster.context(width: 61, height: 61, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 28, y: 28, width: 5, height: 5))
        return try #require(context.makeImage())
    }

    private func reader(_ image: CGImage) throws -> (Int, Int) -> [Int] {
        let width = image.width, height = image.height
        let read = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(read.data).assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return { x, y in (0..<4).map { Int(bytes[(y * width + x) * 4 + $0]) } } // rows top-down
    }

    /// The canvas's GPU drawing runs the dispersion in Core Image's coordinates, whose y points up: a split pointing
    /// up there puts red above the square and blue below, as on the CPU.
    @Test func dispersionInCoreImageFollowsItsCoordinates() throws {
        guard MetalDispersion.shared != nil else { return }
        let image = CIImage(cgImage: try square())
        let parameters = MetalDispersion.Parameters(center: .zero, direction: SIMD2(0, 1), distance: 8, blur: 0, reach: 1,
                                                    radial: 0, sides: 0, spectral: 8, smear: 1)
        let result = try #require(MetalDispersion.apply(to: image, parameters, margin: 18))
        let rendered = try #require(CIContext().createCGImage(result, from: CGRect(x: 0, y: 0, width: 61, height: 61)))
        let pixel = try reader(rendered)
        let above = (19...26).reduce([0, 0]) { [$0[0] + pixel(30, $1)[0], $0[1] + pixel(30, $1)[2]] }
        let below = (34...41).reduce([0, 0]) { [$0[0] + pixel(30, $1)[0], $0[1] + pixel(30, $1)[2]] }
        #expect(above[0] > above[1] * 2, "red above: \(above)")
        #expect(below[1] > below[0] * 2, "blue below: \(below)")
    }

    /// Each new kind adds as a layer that changes what's under it when exported, opens in its filter's panel, and
    /// survives saving, which needs version 16.
    @Test func filterLayersRenderEditAndSave() async throws {
        let session = EditorSession()
        session.createDocument(width: 61, height: 61)
        let image = try square()
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Square"))
        let before = try reader(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
        for kind in [AdjustmentKind.progressiveBlur, .bloomGlow, .rgbSplit] {
            session.addAdjustment(kind)
            #expect(session.adjustmentEditingID != nil)
            await session.beginAdjustmentEditing(try #require(session.adjustmentEditingID))
            #expect(session.filterEdit?.kind == kind.filterKind, "\(kind) opens its filter's panel")
            if kind == .bloomGlow {
                var settings = try #require(session.filterEdit?.settings)
                settings.bloomRadius = 10
                session.updateFilter(settings, preview: true)
            }
            session.finishAdjustmentEditing(commit: true)
        }
        let layers = try #require(session.document?.layers)
        #expect(layers.compactMap(\.adjustment?.kind) == [.progressiveBlur, .bloomGlow, .rgbSplit])
        #expect(layers[2].adjustment?.filterLayer.bloomRadius == 10)
        #expect(layers[1].adjustment?.filterLayer.progressiveStart != nil && layers[3].adjustment?.filterLayer.rgbSplitCenter != nil)

        let snapshot = try #require(session.projectSnapshot())
        let after = try reader(try await ImageExporter.shared.render(snapshot).image)
        #expect((0..<61).contains { x in after(x, 20) != before(x, 20) } || after(30, 30) != before(30, 30), "the layers change the image")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilterLayers-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.compactMap(\.adjustment?.kind) == [.progressiveBlur, .bloomGlow, .rgbSplit])
        var older = snapshot.manifest
        older.version = 15
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    /// The canvas can draw each of them on the GPU, rather than falling back to the slower drawing.
    @Test func theCanvasDrawsThemOnTheGPU() {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        for kind in [AdjustmentKind.progressiveBlur, .bloomGlow] + (MetalDispersion.shared == nil ? [] : [.rgbSplit]) {
            #expect(GPUAdjustment.apply(LayerAdjustment(kind: kind), to: image, scale: 1, mapping: .identity) != nil, "\(kind)")
        }
    }

    /// A gray picture with soft detail and one bright light, rows top-down.
    private func scene(width: Int = 80, height: Int = 60) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 30))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 25, width: 6, height: 6))
        return try #require(context.makeImage())
    }

    /// Each later kind adds as a layer that changes the export, opens in its filter's panel, and survives saving, which
    /// needs version 18.
    @Test func vignetteLensEffectsAndTonalContrastLayersRenderEditAndSave() async throws {
        for kind in [AdjustmentKind.vignette, .lensEffects, .tonalContrast] {
            let session = EditorSession()
            session.createDocument(width: 80, height: 60)
            let image = try scene()
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Scene"))
            let before = try reader(try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image)
            session.addAdjustment(kind)
            await session.beginAdjustmentEditing(try #require(session.adjustmentEditingID))
            #expect(session.filterEdit?.kind == kind.filterKind, "\(kind) opens its filter's panel")
            var settings = try #require(session.filterEdit?.settings)
            settings.vignetteAmount = 80
            settings.tonalAmount = 100
            settings.lens.effect = .mist
            settings.lens.mistStrength = 90
            session.updateFilter(settings, preview: true)
            session.finishAdjustmentEditing(commit: true)
            let layer = try #require(session.document?.layers.last?.adjustment)
            switch kind {
            case .vignette: #expect(layer.filterLayer.vignette?.amount == 80)
            case .tonalContrast: #expect(layer.filterLayer.tonal?.amount == 100)
            default: #expect(layer.filterLayer.lens?.effect == .mist && layer.filterLayer.lens?.mistStrength == 90)
            }
            let snapshot = try #require(session.projectSnapshot())
            #expect(snapshot.manifest.version == ProjectManifest.current)
            let after = try reader(try await ImageExporter.shared.render(snapshot).image)
            let changed = (0..<80).contains { x in (0..<60).contains { y in after(x, y) != before(x, y) } }
            #expect(changed, "\(kind) changes the image")

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilterLayers18-\(UUID()).comp")
            defer { try? FileManager.default.removeItem(at: url) }
            try await ProjectStore.shared.save(snapshot, to: url)
            let loaded = try await ProjectStore.shared.load(from: url)
            #expect(loaded.manifest.layers.last?.adjustment == layer, "\(kind) keeps its settings")
            var older = snapshot.manifest
            older.version = 17
            await #expect(throws: (any Error).self) {
                try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
            }
        }
    }

    /// A Vignette or Tonal Contrast layer drawn on the canvas's GPU looks as the export makes it, on the CPU.
    @Test func vignetteAndTonalContrastMatchOnTheGPU() throws {
        guard MetalFinishing.shared != nil else { return }
        let image = try scene()
        var vignette = LayerAdjustment(kind: .vignette)
        vignette.filterLayer.vignette = VignetteLayerSettings()
        vignette.filterLayer.vignette?.amount = 80
        var tonal = LayerAdjustment(kind: .tonalContrast)
        tonal.filterLayer.tonal = TonalLayerSettings()
        tonal.filterLayer.tonal?.amount = 100
        tonal.filterLayer.tonal?.radius = 6
        for adjustment in [vignette, tonal] {
            let cpu = try reader(try adjustment.apply(image))
            let gpuImage = try #require(GPUAdjustment.apply(adjustment, to: CIImage(cgImage: image), scale: 1, mapping: .identity,
                                                            document: CGSize(width: 80, height: 60)))
            let gpu = try reader(try #require(PixelAdjust.ciContext.createCGImage(gpuImage, from: CGRect(x: 0, y: 0, width: 80, height: 60),
                                                                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)))
            var worst = 0
            for x in stride(from: 0, to: 80, by: 3) { for y in stride(from: 0, to: 60, by: 3) {
                worst = max(worst, zip(cpu(x, y), gpu(x, y)).map { abs($0 - $1) }.max() ?? 0)
            } }
            // The export blurs Tonal Contrast's detail at 8 bits, the canvas in floats: a few levels apart at most.
            #expect(worst <= 5, "\(adjustment.kind): within \(worst) levels")
        }
    }

    /// Lens Effects measures itself by the whole document, not the part of it the canvas is drawing.
    @Test func lensEffectsLayerSizesByTheDocument() throws {
        var adjustment = LayerAdjustment(kind: .lensEffects)
        adjustment.filterLayer.lens = LensEffectSettings()
        adjustment.filterLayer.lens?.effect = .prism
        adjustment.filterLayer.lens?.prismCopies = 1
        adjustment.filterLayer.lens?.prismOffset = 10
        // A light at the right edge of a 200-pixel-wide piece of an 800-pixel document: a copy 10% of 800 = 80 pixels left.
        let piece = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 50))
        let light = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 180, y: 20, width: 10, height: 10))
        let image = light.composited(over: piece)
        let result = try #require(GPUAdjustment.apply(adjustment, to: image, scale: 1, mapping: .identity, document: CGSize(width: 800, height: 400)))
        let pixel = try reader(try #require(PixelAdjust.ciContext.createCGImage(result, from: image.extent, format: .RGBA8,
                                                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)))
        // Rows top-down: y 20–30 up from the bottom of 50 is 20–30 down too.
        #expect(pixel(105, 25)[1] > 40, "the copy lands 80 pixels left")
        #expect(pixel(160, 25)[1] < 10, "not 20, as a 200-pixel picture would put it")
    }

    @Test func theCanvasDrawsTheLaterKindsOnTheGPU() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        for kind in [AdjustmentKind.lensEffects] + (MetalFinishing.shared == nil ? [] : [.vignette, .tonalContrast]) {
            #expect(GPUAdjustment.apply(LayerAdjustment(kind: kind), to: image, scale: 1, mapping: .identity) != nil, "\(kind)")
        }
    }

    /// Sharpen brings out edges as a filter and as a layer, the same on the canvas's GPU as in the export, and a Sharpen
    /// layer needs version 19.
    @Test func sharpenBringsOutEdgesAndSaves() async throws {
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        let edge = try #require(context.makeImage())
        var adjustment = LayerAdjustment(kind: .sharpen)
        adjustment.filterLayer.sharpen = SharpenLayerSettings()
        adjustment.filterLayer.sharpen?.amount = 200
        adjustment.filterLayer.sharpen?.radius = 2
        let pixel = try reader(try adjustment.apply(edge))
        let before = try reader(edge)
        #expect(pixel(18, 10)[0] < before(18, 10)[0] - 5, "darker just before the edge: \(pixel(18, 10))")
        #expect(pixel(21, 10)[0] > before(21, 10)[0] + 5, "lighter just after it: \(pixel(21, 10))")
        #expect(pixel(5, 10) == before(5, 10), "flat areas stay as they are")
        let gpu = try #require(GPUAdjustment.apply(adjustment, to: CIImage(cgImage: edge), scale: 1, mapping: .identity))
        let shown = try reader(try #require(PixelAdjust.ciContext.createCGImage(gpu, from: CGRect(x: 0, y: 0, width: 40, height: 20),
                                                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)))
        for x in [17, 18, 19, 20, 21, 22] { #expect(zip(shown(x, 10), pixel(x, 10)).allSatisfy { abs($0 - $1) <= 2 }, "canvas at \(x)") }

        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.insert(ImportedImage(image: edge, thumbnail: edge, name: "Edge"))
        session.addAdjustment(.sharpen)
        session.adjustmentEditingID = nil
        session.updateAdjustment(try #require(session.activeLayerID), value: adjustment)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sharpen-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers.last?.adjustment == adjustment)
        var older = snapshot.manifest
        older.version = 18
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }
}
