import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor
struct ImageSizeTests {
    @Test func unlockedScrubReachesSizesAboveOneHundredMegapixels() {
        let range = ImageSizeDraft.scrubPixelRange(pixels: 4000, other: 6000, locked: false)
        #expect(range.contains(20_000))
        #expect(range.upperBound == Double(DocumentLimits.maxSide))
        let limited = ImageSizeDraft.scrubPixelRange(pixels: 6000, other: 20_000, locked: false)
        #expect(limited.upperBound == Double(DocumentLimits.maxSurfacePixels) / 20_000)
    }

    @Test func lockedScrubRespectsBothSurfaceAndSideLimits() {
        let range = ImageSizeDraft.scrubPixelRange(pixels: 8000, other: 6000, locked: true)
        #expect(range.contains(16_000))
        let height = range.upperBound * 6000 / 8000
        #expect(abs(range.upperBound * height - Double(DocumentLimits.maxSurfacePixels)) < 0.001)
        let wide = ImageSizeDraft.scrubPixelRange(pixels: 8000, other: 1000, locked: true)
        #expect(wide.upperBound == Double(DocumentLimits.maxSide))
        let tall = ImageSizeDraft.scrubPixelRange(pixels: 1000, other: 8000, locked: true)
        #expect(tall.upperBound * 8 == Double(DocumentLimits.maxSide))
        #expect(tall.lowerBound == 1)
        #expect(wide.lowerBound == 8)
    }

    @Test func resizePreservesLayerIdentityAndUndoRestoresSource() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let original = try #require(session.document)
        let layer = try #require(original.layers.first)
        let result = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 128, height: 96, resolution: 300, sampling: .nearest))
        session.applyImageSize(result)
        #expect(session.document?.width == 128 && session.document?.height == 96)
        #expect(session.document?.resolution == 300)
        #expect(session.activeLayerID == layer.id)
        let asset = try #require(session.document?.layers.first?.asset)
        #expect(asset.image.width == 128 && asset.image.height == 96)
        let bitmap = NSBitmapImageRep(cgImage: asset.image)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).redComponent > 0.95)
        #expect(try #require(bitmap.colorAt(x: 127, y: 0)).alphaComponent == 0)
        session.undo()
        #expect(session.document == original)
        #expect(session.document?.layers.first?.asset?.image === layer.asset?.image)
        session.redo()
        #expect(session.document?.resolution == 300)
    }

    @Test func resolutionOnlyRetainsPixelsAndSurvivesSaveAndExport() async throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 16)
        session.addBlankLayer()
        let before = try #require(session.projectSnapshot())
        let resized = try await ImageResizer.shared.resize(before,
            to: ImageSizeOptions(width: 32, height: 16, resolution: 300))
        #expect(resized.manifest.layers.first?.transform == before.manifest.layers.first?.transform)
        session.applyImageSize(resized)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Size-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(resized, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.resolution == 300)
        let png = try await ImageExporter.shared.pngData(loaded)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(abs((properties[kCGImagePropertyDPIWidth] as? Double ?? 0) - 300) < 1)
        session.undo()
        #expect(session.document?.resolution == 72)
    }

    @Test func rotatedHiddenLayerScalesInDocumentAxesAndInvalidSizeIsRejected() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        await session.importImages([url])
        let snapshot = try #require(session.projectSnapshot())
        let record = try #require(snapshot.manifest.layers.first)
        var manifest = snapshot.manifest
        let transform = LayerTransform(origin: CGPoint(x: -16, y: 4), size: CGSize(width: 64, height: 32), rotation: 90)
        manifest.layers = [ProjectLayerRecord(id: record.id, name: record.name, isVisible: false,
            transform: transform, imageFile: record.imageFile)]
        let input = ProjectSnapshot(manifest: manifest, images: snapshot.images)
        let result = try await ImageResizer.shared.resize(input,
            to: ImageSizeOptions(width: 128, height: 96, resolution: 72, sampling: .nearest))
        let output = try #require(result.manifest.layers.first)
        #expect(!output.isVisible)
        #expect(output.transform.rotation == 0)
        // A 90-degree 64×32 layer becomes 32×64, then scales 2× horizontally and 3× vertically.
        #expect(abs(output.transform.size.width - 64) <= 1)
        #expect(abs(output.transform.size.height - 192) <= 1)
        #expect(output.transform.origin.y < 0)
        await #expect(throws: ProjectError.self) {
            try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: 30_000, height: 30_000, resolution: 72))
        }
        #expect(session.document?.width == 64)
    }
}
