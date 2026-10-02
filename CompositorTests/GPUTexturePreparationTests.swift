import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing
@testable import Compositor

/// Textures made away from the main thread, ahead of the frame that draws them, against the ones a frame uploads.
@MainActor struct GPUTexturePreparationTests {
    /// Colors with soft alpha, premultiplied, as the editor holds a layer's pixels.
    private func pattern(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let i = y * context.bytesPerRow + x * 4, alpha = (x + y) * 255 / (width + height - 2)
            data[i] = UInt8(x * alpha / width); data[i + 1] = UInt8(y * alpha / height)
            data[i + 2] = UInt8((x / 8 + y / 8) % 2 == 0 ? alpha : alpha / 3); data[i + 3] = UInt8(alpha)
        } }
        return context.makeImage()!
    }

    private func gradientMask(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width { data[y * context.bytesPerRow + x] = UInt8(x * 255 / (width - 1)) } }
        return context.makeImage()!
    }

    /// A project of one masked layer, saved as a package.
    private func savedProject() throws -> URL {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        let image = try pattern(300, 200)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        session.document!.layers[session.document!.layers.count - 1].mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(300, 200)))
        let url = FileManager.default.temporaryDirectory.appending(path: "prepared-\(UUID().uuidString).comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// The texture's pixels, as the canvas's context reads them out.
    private func bytes(_ image: CIImage, _ renderer: GPUCanvasRenderer) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        renderer.context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent, format: .RGBA8,
                                colorSpace: renderer.space)
        return bytes
    }

    /// A texture made on another thread holds the very bytes a frame uploads for the same image: a layer and a mask
    /// read lazily from a package and converted as they're copied, a painted layer copied straight, and a 1×1 mask.
    @Test func aTextureMadeAwayFromTheMainThreadHoldsWhatDrawingUploads() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try ProjectStore.readPackage(url)
        let layer = try #require(read.images.values.first?.image), mask = try #require(read.masks.values.first?.image)
        let painted = try pattern(301, 199), solid = try #require(LayerMask.solid(revealing: true)).asset.image
        #expect(!BrushRaster.copiesStraight(layer) && BrushRaster.copiesStraight(painted))
        let device = renderer.device, space = renderer.space
        for (image, isMask) in [(layer, false), (painted, false), (mask, true), (solid, true)] {
            let made = try #require(await Task.detached {
                var copying = Duration.zero, writing = Duration.zero
                return GPUCanvasRenderer.upload(image, mask: isMask, device: device, space: space, copying: &copying, writing: &writing)
            }.value)
            let drawn = try #require(renderer.image(image, mask: isMask))
            #expect(made.extent == drawn.extent)
            let expected = bytes(drawn, renderer)
            #expect(bytes(made, renderer) == expected, "\(image.width)×\(image.height), mask: \(isMask)")
            if image.width > 1 { #expect(Set(expected).count > 2, "not blank") }
        }
    }

    private func sources(_ images: [CGImage]) -> [GPUTextureSource] { images.map { GPUTextureSource(image: $0, mask: false) } }

    /// Adopted textures are what the next frame would have uploaded: it uploads nothing, keeps what it draws, and lets
    /// go of what it only reduces from, as it does its own; what it doesn't use goes a frame later.
    @Test func adoptedTexturesLiveAsTheNextFramesOwn() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let drawn = try pattern(120, 90), reduced = try pattern(120, 90), unused = try pattern(120, 90)
        let prepared = await renderer.prepare(sources([drawn, reduced, unused]))
        // From here on nothing is awaited, so no other test's frame comes between.
        #expect(prepared.count == 3)
        let before = renderer.uploads
        renderer.adopt(prepared)
        #expect(renderer.image(drawn) != nil && renderer.image(reduced, level: 2) != nil)
        #expect(renderer.uploads == before)
        renderer.endFrame()
        #expect(renderer.cachedLevels(of: drawn) == [0])
        #expect(renderer.cachedLevels(of: reduced) == [1, 2])
        #expect(renderer.cachedLevels(of: unused) == [0])
        renderer.endFrame()
        #expect(renderer.cachedLevels(of: unused) == [])
        #expect(renderer.cachedLevels(of: drawn) == [0])
    }

    /// Another window's canvas may draw a frame before the one that adopted textures does; they're still there for it.
    @Test func adoptedTexturesOutlastAFrameOfAnotherCanvas() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let image = try pattern(120, 90)
        let prepared = await renderer.prepare(sources([image]))
        renderer.adopt(prepared)
        renderer.endFrame()
        let before = renderer.uploads
        #expect(renderer.image(image, level: 1) != nil)
        #expect(renderer.uploads == before)
        renderer.endFrame()
        #expect(renderer.cachedLevels(of: image) == [1])
    }

    /// What the canvas already holds isn't made again, and an image asked for twice is made once.
    @Test func preparingLeavesOutWhatIsHeld() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let held = try pattern(120, 90), other = try pattern(120, 90)
        #expect(renderer.image(held) != nil)
        #expect(renderer.notHeld(sources([held, other, other])).map { ObjectIdentifier($0.image) } == [ObjectIdentifier(other)])
    }

    /// Adopting never replaces a texture the canvas made meanwhile.
    @Test func adoptingReplacesNothing() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let image = try pattern(120, 90)
        let prepared = await renderer.prepare(sources([image]))
        let uploaded = try #require(renderer.image(image))
        renderer.adopt(prepared)
        #expect(renderer.image(image) === uploaded)
    }

    /// A document with an image too large for a texture can't be drawn on the GPU, so nothing is made for it.
    @Test func nothingIsMadeForADocumentWithAnImageTooLargeForATexture() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let small = try pattern(120, 90), wide = try pattern(16_385, 2)
        let prepared = await renderer.prepare(sources([small, wide]))
        #expect(prepared.count == 0)
    }

    /// Preparations asked for at once, as two windows opening projects ask, take turns, so their textures and copies
    /// aren't all held at the same time: a small one asked for after a large one finishes after it. Each still makes
    /// what it's asked for, one that makes nothing included.
    @Test(.timeLimit(.minutes(10)))
    func preparationsTakeTurns() async throws {
        final class Order { var finished: [String] = [] }
        let renderer = try #require(GPUCanvasRenderer.shared)
        let large = try pattern(4000, 3000), tooLarge = try pattern(16_385, 2), small = try pattern(120, 90)
        let order = Order()
        let preparing = [("large", large), ("too large", tooLarge), ("small", small)].map { name, image in
            Task {
                let count = await renderer.prepare(sources([image])).count
                order.finished.append(name)
                return count
            }
        }
        var counts: [Int] = []
        for task in preparing { counts.append(await task.value) }
        #expect(counts == [1, 0, 1])
        #expect(order.finished.firstIndex(of: "large")! < order.finished.firstIndex(of: "small")!)
    }

    /// A preparation cancelled while it waits its turn makes nothing; the one ahead of it is unaffected.
    @Test(.timeLimit(.minutes(10)))
    func aPreparationCancelledWhileItWaitsMakesNothing() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let first = try pattern(1500, 1000), second = try pattern(120, 90)
        let preparingFirst = Task { await renderer.prepare(sources([first])) }
        let preparingSecond = Task { await renderer.prepare(sources([second])) }
        // Both start before this goes on: the first takes the turn and the second waits for it.
        await Task.yield()
        preparingSecond.cancel()
        #expect(await preparingSecond.value.count == 0)
        #expect(await preparingFirst.value.count == 1)
    }

    /// A folder's or an adjustment's mask too large for a texture is left out of the frame, which still draws on the
    /// GPU, so the layers' textures are made all the same.
    @Test func aMaskTheCanvasLeavesOutDoesntStopTheLayers() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let session = EditorSession()
        session.createDocument(width: 16_400, height: 8)
        let image = try pattern(120, 8)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        var levels = ImageLayer(name: "Levels", blankSize: CGSize(width: 16_400, height: 8))
        levels.adjustment = LayerAdjustment(kind: .levels)
        levels.mask = LayerMask(asset: try LayerMask.asset(from: gradientMask(16_400, 8)))
        session.document!.layers.append(levels)
        let sources = try #require(session.document).canvasSources
        #expect(sources.map { ObjectIdentifier($0.image) } == [ObjectIdentifier(image)])
        #expect(await renderer.prepare(sources).count == 1)
    }

    /// The textures are made away from the main thread, which is free meanwhile.
    @Test func preparingLetsTheMainActorRun() async throws {
        final class Flag { var raised = false }
        let renderer = try #require(GPUCanvasRenderer.shared)
        let flag = Flag()
        Task { flag.raised = true }
        let prepared = await renderer.prepare(sources([try pattern(1500, 1000)]))
        #expect(prepared.count == 1)
        #expect(flag.raised)
    }

    /// A preparation cancelled before it starts makes nothing.
    @Test func aCancelledPreparationMakesNothing() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let images = try (0..<6).map { _ in try pattern(200, 150) }
        // Cancelled before the main actor gets to it, so it starts cancelled.
        let preparing = Task { await renderer.prepare(sources(images)) }
        preparing.cancel()
        #expect(await preparing.value.count == 0)
        #expect(images.allSatisfy { renderer.cachedLevels(of: $0).isEmpty })
    }

    /// A frame counts each image it has to upload, and not one it already holds, nor a transient one.
    @Test func framesCountTheImagesTheyUpload() throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let image = try pattern(64, 48), reduced = try pattern(64, 48), stroke = try pattern(64, 48)
        let before = renderer.uploads
        #expect(renderer.image(image) != nil)
        #expect(renderer.uploads == before + 1)
        #expect(renderer.image(image) != nil)
        #expect(renderer.image(stroke, transient: true) != nil)
        #expect(renderer.uploads == before + 1)
        // Reduced, it's uploaded once, at full size, to reduce from.
        #expect(renderer.image(reduced, level: 2) != nil)
        #expect(renderer.uploads == before + 2)
    }
}
