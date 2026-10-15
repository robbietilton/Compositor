import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor
struct GIFOnionSkinTests {
    private func session() async throws -> EditorSession {
        let url = try ImageImportTests().animatedGIFFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        session.gifOnionSkin.isEnabled = true
        await session.selectGIFTimelineFrame(1)
        await load(session)
        return session
    }

    private func load(_ session: EditorSession) async {
        await session.gifOnionSkin.update(for: session, completion: {})?.value
    }

    private func solid(_ color: CGColor) throws -> ImportedImage {
        let context = try BrushRaster.context(width: 32, height: 24, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Frame")
    }

    private func images(_ session: EditorSession, canvas: CanvasView) throws -> (cpu: CGImage, gpu: CGImage) {
        canvas.synchronizeDisplay()
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.allowsGPU = false
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let cpu = try #require(context.makeImage())
        let renderer = try #require(GPUCanvasRenderer.shared)
        let frame = try #require(canvas.gpuFrame(size: canvas.bounds.size))
        let gpu = try #require(renderer.context.createCGImage(frame, from: canvas.bounds, format: .RGBA8,
                                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        return (cpu, gpu)
    }

    private func canvas(_ session: EditorSession, zoom: CGFloat = 3) throws -> CanvasView {
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let size = try #require(session.document?.size)
        session.viewport.resize(to: canvas.bounds.size, backingScale: 1, documentSize: size)
        session.viewport.setZoom(zoom, anchoredAt: session.viewport.center, documentSize: size)
        return canvas
    }

    private func sample(_ image: CGImage, session: EditorSession, point: CGPoint = CGPoint(x: 16, y: 12)) throws -> [UInt8] {
        let size = try #require(session.document?.size)
        let view = session.viewport.viewPoint(from: point, documentSize: size)
        return try ImageImportTests().rgba(image, x: Int(view.x), y: Int(view.y))
    }

    @Test func navigationPlaybackAndMaskOnlyViewLeaveTheDocumentUntouched() async throws {
        let session = try await session()
        let id = try #require(session.activeLayerID)
        let before = session.document, count = session.history.undoCount
        #expect(session.gifOnionSkin.opacity == 0.25)
        let ghost = try #require(session.gifOnionSkin.layer(in: session))
        let ghostPixel = try ImageImportTests().rgba(try #require(ghost.asset?.image), x: 16, y: 12)
        #expect(ghostPixel[0] > 240 && ghostPixel[2] < 15, "Ghost pixels: \(ghostPixel)")
        session.gifOnionSkin.opacity = 0.5
        session.toggleGIFPlayback(for: id)
        #expect(session.gifOnionSkin.layer(in: session) == nil)
        await load(session)
        session.stopGIFPlayback(for: id)
        await load(session)
        #expect(session.gifOnionSkin.isEnabled && session.gifOnionSkin.layer(in: session) != nil)
        session.viewsMaskAlone = true
        #expect(session.gifOnionSkin.layer(in: session) == nil)
        session.viewsMaskAlone = false
        session.selectLayer(nil)
        #expect(session.gifOnionSkin.layer(in: session) == nil)
        await load(session)
        session.selectLayer(id)
        await load(session)
        #expect(session.gifTimelineSelectedFrameIndex == 1 && session.selectedLayerIDs == [id])
        #expect(session.document == before && session.history.undoCount == count)
        await session.selectGIFTimelineFrame(0)
        #expect(session.gifOnionSkin.requestedFrame(in: session) == nil)
        session.gifOnionSkin.isEnabled = false
        await session.selectGIFTimelineFrame(1)
        #expect(session.gifOnionSkin.layer(in: session) == nil)
    }

    @Test func timelineOrderAndEditedPixelsDetermineThePreviousFrame() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        let duplicate = session.gifTimelineSelectedFrameIndex
        #expect(duplicate != 1)
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == 1)
        session.moveGIFFrame(at: 0, to: 1, for: id)
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == 0)
        let green = try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        session.document?.layers[0].gifAnimation?.framePixels[0] = green
        #expect(session.gifOnionSkin.layer(in: session)?.asset?.image === green.image)
        await session.deleteGIFFrame(at: 0, for: id)
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == 1)
        session.undo()
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session)?.asset?.image === green.image)
    }

    @Test func directionUsesOnlyAnAvailableNeighborAndResetsOnReopening() async throws {
        let session = try await session()
        let before = session.document, count = session.history.undoCount
        #expect(session.gifOnionSkin.direction == .previous)
        session.gifOnionSkin.direction = .next
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session) == nil)
        await session.selectGIFTimelineFrame(0)
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == 1)
        let next = try #require(session.gifOnionSkin.layer(in: session)?.asset?.image)
        #expect(try ImageImportTests().rgba(next, x: 16, y: 12)[2] > 240)
        session.gifOnionSkin.direction = .previous
        #expect(session.gifOnionSkin.requestedFrame(in: session) == nil)
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session) == nil)

        session.gifOnionSkin.direction = .next
        let pending = session.gifOnionSkin.update(for: session, completion: {})
        session.gifOnionSkin.direction = .previous
        await pending?.value
        #expect(session.gifOnionSkin.layer(in: session) == nil)
        session.gifOnionSkin.direction = .next
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session)?.asset?.image != nil)
        await session.selectGIFTimelineFrame(1)
        #expect(session.document == before && session.history.undoCount == count)
        session.installProject(try #require(session.projectSnapshot()), from: URL(fileURLWithPath: "/tmp/onion-direction.comp"))
        #expect(session.gifOnionSkin.direction == .previous && !session.gifOnionSkin.isEnabled)
    }

    @Test func nextPreviewFollowsReorderingEditsMasksAndDeletion() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        await session.duplicateGIFFrame(at: 1, for: id)
        let duplicate = session.gifTimelineSelectedFrameIndex
        session.moveGIFFrame(at: 0, to: 2, for: id)
        await session.selectGIFTimelineFrame(1)
        session.gifOnionSkin.direction = .next
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == duplicate)
        let green = try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        session.document?.layers[0].gifAnimation?.framePixels[duplicate] = green
        let hidden = try #require(LayerMask.solid(revealing: false))
        session.document?.layers[0].gifFrameMasks[duplicate] = hidden
        let ghost = try #require(session.gifOnionSkin.layer(in: session))
        #expect(ghost.asset?.image === green.image && ghost.mask == hidden)
        await session.deleteGIFFrame(at: duplicate, for: id)
        await load(session)
        #expect(session.gifOnionSkin.requestedFrame(in: session)?.frameIndex == 0)
        session.undo()
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session)?.asset?.image === green.image)
    }

    @Test(arguments: [(CGFloat(1), false), (CGFloat(3), false), (CGFloat(1), true), (CGFloat(3), true)])
    func opaqueFramesBlendOnBothCanvasesAndExportStaysClean(zoom: CGFloat, previewsNext: Bool) async throws {
        let session = try await session()
        if previewsNext {
            session.gifOnionSkin.direction = .next
            await session.selectGIFTimelineFrame(0)
            await load(session)
        }
        let canvas = try canvas(session, zoom: zoom)
        let before = session.document, count = session.history.undoCount
        let ghost = try #require(session.gifOnionSkin.layer(in: session)?.asset?.image)
        let current = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        let neighborPixel = try ImageImportTests().rgba(ghost, x: 16, y: 12)
        let currentPixel = try ImageImportTests().rgba(current, x: 16, y: 12)
        func expectBlend(_ pixel: [UInt8], opacity: Double) {
            for component in 0..<3 {
                let expected = Double(neighborPixel[component]) * opacity + Double(currentPixel[component]) * (1 - opacity)
                #expect(abs(Double(pixel[component]) - expected) <= 3, "Blend pixels: \(pixel)")
            }
        }
        let rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] {
            let pixel = try sample(image, session: session)
            expectBlend(pixel, opacity: 0.25)
        }
        session.gifOnionSkin.opacity = 0.5
        #expect(canvas.synchronizeDisplay())
        let changed = try images(session, canvas: canvas)
        for image in [changed.cpu, changed.gpu] {
            let pixel = try sample(image, session: session)
            expectBlend(pixel, opacity: 0.5)
        }
        let snapshot = try #require(session.projectSnapshot())
        let exported = try await ImageExporter.shared.render(snapshot)
        #expect(try ImageImportTests().rgba(exported.image, x: 16, y: 12) == currentPixel)
        #expect(session.document == before && session.history.undoCount == count)
        let reopened = EditorSession()
        reopened.installProject(snapshot, from: URL(fileURLWithPath: "/tmp/onion-preview.comp"))
        #expect(!reopened.gifOnionSkin.isEnabled && reopened.gifOnionSkin.layer(in: reopened) == nil)
    }

    @Test func previousMaskAndSharedMaskControlOnlyTheGhost() async throws {
        let session = try await session(), canvas = try canvas(session)
        let current = try #require(session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        let currentPixel = try ImageImportTests().rgba(current, x: 16, y: 12)
        session.document?.layers[0].gifFrameMasks[0] = LayerMask.solid(revealing: false)
        var rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] { let pixel = try sample(image, session: session); #expect(zip(pixel, currentPixel).allSatisfy { abs(Int($0) - Int($1)) <= 2 }) }
        session.document?.layers[0].gifFrameMasks[0]?.isEnabled = false
        rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] { #expect(try sample(image, session: session)[0] > 60) }
        session.document?.layers[0].gifFrameMasks[0] = LayerMask.solid(revealing: true)
        session.document?.layers[0].mask = LayerMask.solid(revealing: false)
        rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] {
            let pixel = try sample(image, session: session)
            #expect(abs(Int(pixel[0]) - Int(pixel[2])) <= 2)
        }
    }

    @Test func transformsAndLayersAboveKeepTheGhostInItsPlace() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        session.document?.layers[0].transform.rotation = 25
        let canvas = try canvas(session)
        var rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] { #expect(try sample(image, session: session)[0] > 60) }
        let green = try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        session.insert(green)
        session.selectLayer(id)
        rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] { let pixel = try sample(image, session: session); #expect(pixel[0] < 15 && pixel[1] > 240 && pixel[2] < 15, "Covering layer pixels: \(pixel)") }
    }

    @Test(arguments: [false, true])
    func pendingLayerTransformKeepsTheGhostsSharedMaskPlacement(linked: Bool) async throws {
        let session = try await session()
        let original = try #require(session.activeLayer?.transform)
        var mask = try LayerMask.revealing(nil, over: original, width: 32, height: 24)
        var placement = original
        placement.origin.x += 4
        mask.placement = placement
        mask.isLinked = linked
        session.document?.layers[0].mask = mask
        let before = session.document, history = session.history.undoCount
        session.beginTransform()
        var moved = original
        moved.origin.x += 8
        session.previewTransform(moved)
        let ghost = try #require(session.gifOnionSkin.layer(in: session))
        #expect(ghost.transform == moved)
        #expect(ghost.mask?.placement == mask.placement(movingLayer: original, to: moved))
        #expect(session.document == before && session.history.undoCount == history)
    }

    @Test func supersededDecodesCannotLeaveAGhostOnAnotherLayer() async throws {
        let session = try await session()
        let id = try #require(session.activeLayerID)
        session.gifOnionSkin.clear()
        var completions = 0
        let old = session.gifOnionSkin.update(for: session) { completions += 1 }
        session.selectLayer(nil)
        session.gifOnionSkin.update(for: session) { completions += 1 }
        await old?.value
        #expect(completions == 0 && session.gifOnionSkin.layer(in: session) == nil)
        session.selectLayer(id)
        let superseded = session.gifOnionSkin.update(for: session, completion: {})
        session.selectLayer(nil)
        await superseded?.value
        session.selectLayer(id)
        await load(session)
        #expect(session.gifOnionSkin.layer(in: session) != nil)
    }

    @Test func ghostDoesNotExpandClippingStackCoverage() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        session.document?.layers[0].gifFrameMasks[1] = LayerMask.solid(revealing: false)
        var clipped = ImageLayer(asset: try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1)), origin: .zero)
        clipped.maskSourceID = id
        session.document?.layers.append(clipped)
        let canvas = try canvas(session)
        let ghost = try #require(session.gifOnionSkin.layer(in: session)?.asset?.image)
        let previous = try ImageImportTests().rgba(ghost, x: 16, y: 12)
        let rendered = try images(session, canvas: canvas)
        session.gifOnionSkin.isEnabled = false
        let baseline = try images(session, canvas: canvas)
        for (image, withoutGhost) in [(rendered.cpu, baseline.cpu), (rendered.gpu, baseline.gpu)] {
            let pixel = try sample(image, session: session)
            let below = try sample(withoutGhost, session: session)
            for component in 0..<3 {
                let expected = Double(previous[component]) * 0.25 + Double(below[component]) * 0.75
                #expect(abs(Double(pixel[component]) - expected) <= 3, "The ghost must leave the clipped layer hidden: \(pixel).")
            }
        }
    }

    @Test func maskPaintingKeepsTheCurrentFrameAsItsTarget() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        await session.addGIFFrameMask(at: 1, for: id)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 6, hardness: 1, red: 0, green: 0, blue: 0)
        session.maskPaintWhite = false
        let canvas = try canvas(session)
        let count = session.history.undoCount
        session.beginBrush(at: CGPoint(x: 8, y: 12))
        let stroke = try #require(session.brushStroke)
        #expect(stroke.isMask && stroke.layer.gifAnimation?.selectedFrameIndex == 1)
        let target = try #require(stroke.layer.asset?.image)
        #expect(target === session.activeLayer.flatMap { session.displayedAsset(for: $0)?.image })
        let rendered = try images(session, canvas: canvas)
        for image in [rendered.cpu, rendered.gpu] {
            let pixel = try sample(image, session: session, point: CGPoint(x: 24, y: 12))
            #expect(abs(Int(pixel[0]) - 67) <= 3 && abs(Int(pixel[2]) - 191) <= 3)
        }
        #expect(session.finishBrushImmediately())
        #expect(session.history.undoCount == count + 1 && session.gifTimelineSelectedFrameIndex == 1)
        #expect(session.activeLayer?.gifFrameMasks[0] == nil)
        let exported = try await ImageExporter.shared.render(try #require(session.projectSnapshot()))
        #expect(try ImageImportTests().rgba(exported.image, x: 8, y: 12)[3] == 0)
    }

    @Test func ghostEffectsDoNotReplaceTheCurrentFramesEffectsCache() async throws {
        let session = try await session(), id = try #require(session.activeLayerID)
        session.document?.layers[0].effects = LayerEffects(colorOverlay: ColorOverlayEffect(red: 0, green: 1, blue: 0, opacity: 0.5))
        let canvas = try canvas(session)
        var rendered = try images(session, canvas: canvas)
        // Effects finish asynchronously; verify the settled preview rather than the initial raw pixels.
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let pixel = try sample(rendered.gpu, session: session)
            if pixel[1] > 120 && pixel[0] < 40 && pixel[2] < 110 { break }
            try await Task.sleep(for: .milliseconds(20))
            rendered = try images(session, canvas: canvas)
        }
        for image in [rendered.cpu, rendered.gpu] {
            let pixel = try sample(image, session: session)
            #expect(pixel[1] > 120 && pixel[0] < 40 && pixel[2] < 110, "Both frames' effects should be present: \(pixel).")
        }
        let cached = try #require(session.effectsPreviews.rendered(id)?.image)
        let current = try ImageImportTests().rgba(cached, x: 16, y: 12)
        #expect(current[2] > current[0] + 80, "The current frame's cache must keep blue, not the ghost's red.")
    }


}
