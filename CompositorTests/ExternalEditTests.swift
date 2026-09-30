import AppKit
import Testing
@testable import Compositor

@MainActor
struct ExternalEditTests {
    private let app = ExternalEditorApp(url: URL(fileURLWithPath: "/Applications/Upscaler.app"))

    private func image(width: Int, height: Int, transparentCorner: Bool = false, opaque: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if transparentCorner { context.clear(CGRect(x: 0, y: 0, width: width / 2, height: height / 2)) }
        return try #require(context.makeImage())
    }

    private func asset(_ image: CGImage) throws -> ImportedImage {
        ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Result")
    }

    /// A document with one 20 × 10 image layer, and the job that sends it out. The first tests replace the pixels
    /// in place at the layer's size; the default (a new layer, the canvas enlarged) has tests of its own below.
    private func sentLayer(_ options: ExternalEditOptions = ExternalEditOptions(keepsOriginal: false, enlargesCanvas: false)) throws -> (EditorSession, ExternalEditJob) {
        let session = EditorSession()
        session.insert(try asset(image(width: 20, height: 10)))
        let document = try #require(session.document)
        let layer = try #require(session.activeLayer)
        let folder = FileManager.default.temporaryDirectory
        let job = ExternalEditJob(documentID: document.id, layerID: layer.id, app: app,
                                  source: folder.appendingPathComponent("Layer 1 ABCD1234.png"), folder: folder,
                                  scoped: false, startedAt: Date(), original: try #require(layer.asset?.image),
                                  transform: layer.transform, options: options)
        return (session, job)
    }

    @Test func resultsAreFilesNamedAfterTheSourceSavedAfterItWasSent() {
        let folder = URL(fileURLWithPath: "/tmp/edits")
        let source = folder.appendingPathComponent("Portrait 1A2B3C4D.png")
        let start = Date()
        func matches(_ name: String, modified: Date? = nil) -> Bool {
            ExternalEditMatch.isResult(folder.appendingPathComponent(name), for: source, startedAt: start,
                                       modified: modified ?? start.addingTimeInterval(5))
        }
        #expect(matches("Portrait 1A2B3C4D-gigapixel-standard-scale-2_00x.png"))
        #expect(matches("upscaled_Portrait 1A2B3C4D.TIFF"))
        #expect(matches("portrait 1a2b3c4d-x2.jpg"))
        // As Gigapixel 8 named a real result, with a custom suffix and the .jpeg extension.
        #expect(ExternalEditMatch.isResult(folder.appendingPathComponent("00005-2 1A8B2B3E-topaz.jpeg"),
                                           for: folder.appendingPathComponent("00005-2 1A8B2B3E.png"), startedAt: start,
                                           modified: start.addingTimeInterval(30)))
        #expect(!matches("Portrait 1A2B3C4D.png"), "the file sent out is not its own result")
        #expect(!matches("Portrait 1A2B3C4D-gigapixel.psd"), "a format Compositor can't read back")
        #expect(!matches("Portrait 99999999-gigapixel.png"), "another edit's result")
        #expect(!matches("Portrait 1A2B3C4D-old.png", modified: start.addingTimeInterval(-60)), "saved before this edit")
    }

    @Test func sourceNamesAreSafeAndUnique() {
        let first = ExternalEditMatch.sourceName(for: "Sky/Clouds: final")
        let second = ExternalEditMatch.sourceName(for: "Sky/Clouds: final")
        #expect(first != second)
        #expect(!first.contains("/") && !first.contains(":"))
        #expect(first.hasPrefix("Sky-Clouds- final ") && first.hasSuffix(".png"))
        #expect(ExternalEditMatch.sourceName(for: "   ").hasPrefix("Layer "))
    }

    @Test func resultReplacesThePixelsInPlaceAsOneUndoStep() throws {
        let (session, job) = try sentLayer()
        let before = try #require(session.document)
        let upscaled = try image(width: 80, height: 40)
        try session.applyExternalResult(try asset(upscaled), for: job)
        let layer = try #require(session.document?.layers.first)
        #expect(session.document?.layers.count == 1)
        #expect(layer.id == job.layerID)
        #expect(layer.asset?.image === upscaled)
        #expect(layer.transform == job.transform, "the layer gains detail, not size on the canvas")
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document?.layers.first?.asset?.image === upscaled)
    }

    @Test func layerMaskIsResampledOntoTheNewPixelGrid() throws {
        let (session, job) = try sentLayer()
        let gray = try BrushRaster.context(width: 20, height: 10, mask: true)
        gray.setFillColor(gray: 1, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: try #require(gray.makeImage())))
        try session.applyExternalResult(try asset(image(width: 80, height: 40)), for: job)
        let mask = try #require(session.document?.layers.first?.mask)
        #expect(mask.asset.image.width == 80 && mask.asset.image.height == 40)
        #expect(LayerMask.isValid(mask.asset.image))
    }

    @Test func layerChangedMeanwhileKeepsItsChangesAndTheResultArrivesAbove() throws {
        let (session, job) = try sentLayer()
        session.document?.layers[0].transform.origin.x += 5
        let upscaled = try image(width: 80, height: 40)
        try session.applyExternalResult(try asset(upscaled), for: job)
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 2)
        #expect(layers[0].asset?.image === job.original)
        #expect(layers[1].asset?.image === upscaled)
        #expect(layers[1].transform == job.transform)
        #expect(layers[1].name == "Result (Upscaler)")
        #expect(session.activeLayerID == layers[1].id)
    }

    @Test func resultForAClosedDocumentIsIgnored() throws {
        let (session, job) = try sentLayer()
        session.clearProject()
        session.insert(try asset(image(width: 4, height: 4)))
        try session.applyExternalResult(try asset(image(width: 80, height: 40)), for: job)
        #expect(session.document?.layers.count == 1)
        #expect(session.document?.layers.first?.asset?.image.width == 4)
    }

    @Test func flattenedResultGetsTheOriginalTransparencyBack() throws {
        let original = try image(width: 20, height: 20, transparentCorner: true)
        let flattened = try image(width: 40, height: 40, opaque: true)
        let restored = try ExternalEditPixels.keepingTransparency(of: original, in: flattened)
        #expect(restored.width == 40)
        let bitmap = NSBitmapImageRep(cgImage: restored)
        // CGContext origin is bottom-left; NSBitmapImageRep reads from the top.
        #expect(try #require(bitmap.colorAt(x: 5, y: 35)).alphaComponent < 0.01)
        #expect(try #require(bitmap.colorAt(x: 35, y: 5)).alphaComponent > 0.99)
        // A result that kept its own transparency, or an opaque original, is left alone.
        let transparent = try image(width: 40, height: 40, transparentCorner: true)
        #expect(try ExternalEditPixels.keepingTransparency(of: original, in: transparent) === transparent)
        #expect(try ExternalEditPixels.keepingTransparency(of: flattened, in: flattened) === flattened)
    }

    @Test func watcherWaitsForAResultThatHasFinishedWriting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalEdit-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent(ExternalEditMatch.sourceName(for: "Layer"))
        let picture = try image(width: 8, height: 8)
        try ExternalEditBridge.write(picture, to: source)
        let start = Date()
        let stem = source.deletingPathExtension().lastPathComponent
        let result = folder.appendingPathComponent("\(stem)-gigapixel.png")
        // A file still being written first: the watcher must not take it.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("\(stem)-partial.png"))
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? ExternalEditBridge.write(picture, to: result)
        }
        let found = await ExternalEditBridge.waitForResult(in: folder, for: source, startedAt: start,
                                                           interval: .milliseconds(50))
        #expect(found?.lastPathComponent == result.lastPathComponent)
    }

    @Test func watcherStopsWhenTheEditIsNoLongerWanted() async {
        let folder = FileManager.default.temporaryDirectory
        let found = await ExternalEditBridge.waitForResult(in: folder, for: folder.appendingPathComponent("Nothing \(UUID()).png"),
                                                           startedAt: Date(), interval: .milliseconds(20)) { false }
        #expect(found == nil)
    }

    @Test func byDefaultTheResultIsANewLayerOverTheHiddenOriginalAtFullSize() throws {
        let (session, job) = try sentLayer(ExternalEditOptions())
        // A second layer, a guide and a layer clipped to the one sent out, to see the document scale around them.
        let other = ImageLayer(asset: try asset(image(width: 4, height: 4)), origin: CGPoint(x: 2, y: 3))
        session.document?.layers.append(other)
        var clipped = ImageLayer(asset: try asset(image(width: 4, height: 4)), origin: .zero)
        clipped.maskSourceID = job.layerID
        session.document?.layers.append(clipped)
        session.document?.guides = [CanvasGuide(id: UUID(), axis: .vertical, position: 5)]
        session.document?.layers[0].effects = LayerEffects(stroke: StrokeEffect(size: 2))
        let before = try #require(session.document)
        let upscaled = try image(width: 80, height: 40)
        try session.applyExternalResult(try asset(upscaled), for: job)
        let document = try #require(session.document)
        #expect(document.size == CGSize(width: before.size.width * 4, height: before.size.height * 4))
        let original = try #require(document.layers.first { $0.id == job.layerID })
        #expect(!original.isVisible && original.asset?.image === job.original, "kept, hidden, untouched")
        let result = try #require(document.layers.first { $0.asset?.image === upscaled })
        #expect(document.layers.firstIndex { $0.id == result.id } == document.layers.firstIndex { $0.id == job.layerID }.map { $0 + 1 })
        #expect(result.transform.size == CGSize(width: 80, height: 40), "shown at 100%")
        #expect(result.name == "Result (Upscaler)")
        #expect(result.effects?.stroke?.size == 8, "the stroke grows with the layer's resolution")
        #expect(session.activeLayerID == result.id)
        #expect(document.layers.first { $0.id == other.id }?.transform == LayerTransform(origin: CGPoint(x: 8, y: 12), size: CGSize(width: 16, height: 16)))
        #expect(document.layers.first { $0.id == other.id }?.asset?.image === other.asset?.image, "other layers keep their pixels")
        #expect(document.layers.first { $0.id == clipped.id }?.maskSourceID == result.id)
        #expect(document.guides.first?.position == 20)
        session.undo()
        #expect(session.document == before)
    }

    @Test func enlargingPastTheLargestCanvasPlacesTheResultAtTheLayersSize() throws {
        let session = EditorSession()
        session.createDocument(width: 20_000, height: 100)
        session.insert(try asset(image(width: 20, height: 10)))
        let layer = try #require(session.activeLayer)
        let job = ExternalEditJob(documentID: try #require(session.document?.id), layerID: layer.id, app: app,
                                  source: URL(fileURLWithPath: "/tmp/x.png"), folder: URL(fileURLWithPath: "/tmp"), scoped: false,
                                  startedAt: Date(), original: try #require(layer.asset?.image), transform: layer.transform)
        try session.applyExternalResult(try asset(image(width: 80, height: 40)), for: job)
        #expect(session.document?.width == 20_000)
        #expect(session.activeLayer?.transform == layer.transform)
        #expect(session.externalEditError != nil, "says why the canvas didn't grow")
    }

    @Test func scalingTheDocumentScalesBlursMeasuredInDocumentPixels() throws {
        var adjustment = LayerAdjustment(kind: .gaussianBlur)
        adjustment.blurRadius = 10
        var layer = ImageLayer(name: "Blur", blankSize: CGSize(width: 10, height: 10))
        layer.adjustment = adjustment
        let document = CanvasDocument(width: 10, height: 10, layers: [layer])
        let scaled = try #require(document.scaled(by: 3))
        #expect(scaled.size == CGSize(width: 30, height: 30))
        #expect(scaled.layers[0].adjustment?.blurRadius == 30)
        #expect(document.scaled(by: 4_000) == nil)
    }
}
