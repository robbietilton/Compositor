import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct ExportTests {
    private func snapshot(rotation: CGFloat = 0, flip: Bool = false) throws -> ProjectSnapshot {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        let image = try #require(context.makeImage())
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 1, y: 1), size: CGSize(width: 4, height: 4),
                                       rotation: rotation, flipX: flip, sampling: .nearest)
        let record = ProjectLayerRecord(id: id, name: "Red", isVisible: true, transform: transform,
                                        imageFile: "\(id).png")
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 6, height: 6,
            activeLayerID: id, layers: [record]), images: [id: ImportedImage(image: image, thumbnail: image, name: "Red")])
    }

    @Test func pngPreservesDimensionsAlphaOrientationAndTransforms() async throws {
        for (rotation, flip, redX, redY, clearX, clearY) in [
            (CGFloat(0), false, 1, 1, 4, 1), (0, true, 4, 1, 1, 1), (90, false, 1, 1, 1, 4)
        ] {
            let data = try await ImageExporter.shared.pngData(snapshot(rotation: rotation, flip: flip))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 6 && image.height == 6)
            #expect(image.colorSpace?.name == CGColorSpace.sRGB)
            let bitmap = NSBitmapImageRep(cgImage: image)
            #expect(try #require(bitmap.colorAt(x: redX, y: redY)).redComponent > 0.99)
            #expect(try #require(bitmap.colorAt(x: redX, y: redY)).alphaComponent == 1)
            #expect(try #require(bitmap.colorAt(x: clearX, y: clearY)).alphaComponent == 0)
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
        }
    }

    @Test func orderVisibilityClippingAndAtomicOverwrite() async throws {
        let original = try snapshot()
        let blueContext = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        blueContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        blueContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let blue = try #require(blueContext.makeImage()), id = UUID()
        var images = original.images
        images[id] = ImportedImage(image: blue, thumbnail: blue, name: "Blue")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        for visible in [true, false] {
            var manifest = original.manifest
            manifest.layers.append(ProjectLayerRecord(id: id, name: "Blue", isVisible: visible,
                transform: LayerTransform(origin: CGPoint(x: -2, y: -2), size: CGSize(width: 10, height: 10)),
                imageFile: "\(id).png"))
            try await ImageExporter.shared.exportPNG(ProjectSnapshot(manifest: manifest, images: images), to: url)
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
            let pixel = try #require(bitmap.colorAt(x: 1, y: 1))
            #expect(visible ? pixel.blueComponent > 0.99 : pixel.redComponent > 0.99)
            #expect(bitmap.pixelsWide == 6 && bitmap.pixelsHigh == 6)
        }
    }

    @Test func blankCanvasAndOversizedCanvas() async throws {
        let blank = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 2, height: 2,
            activeLayerID: nil, layers: []), images: [:])
        let data = try await ImageExporter.shared.pngData(blank)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(try #require(bitmap.colorAt(x: 1, y: 1)).alphaComponent == 0)
        let huge = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 30_000, height: 30_000,
            activeLayerID: nil, layers: []), images: [:])
        await #expect(throws: ExportError.self) { try await ImageExporter.shared.pngData(huge) }
    }

    @Test func rotatedChineseBoxTextExportsToPNGAndJPEG() async throws {
        let style = LayerTextStyle(content: "中文与 English 👋 自动换行", fontPostScriptName: "Helvetica",
            fontSizePoints: 24, red: 0.1, green: 0.2, blue: 0.8, alpha: 1, alignment: .center,
            lineSpacingPoints: 5, trackingPoints: 1, layout: .box(width: 120))
        let rendered = try TextLayoutSession(style: style, resolution: 144).render()
        let id = UUID()
        let transform = LayerTransform(origin: CGPoint(x: 40, y: 30), size: rendered.naturalSize,
                                       rotation: 28, flipX: true)
        let record = ProjectLayerRecord(id: id, name: "Text", isVisible: true, transform: transform,
            imageFile: "\(id).png", text: style)
        let asset = ImportedImage(image: rendered.image, thumbnail: rendered.image, name: "Text")
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(resolution: 144, documentID: UUID(),
            width: 320, height: 220, activeLayerID: id, layers: [record]), images: [id: asset])

        let png = try await ImageExporter.shared.pngData(snapshot)
        let pngBitmap = try #require(NSBitmapImageRep(data: png))
        var visiblePixels = 0
        for y in 0..<pngBitmap.pixelsHigh {
            for x in 0..<pngBitmap.pixelsWide where (pngBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                visiblePixels += 1
            }
        }
        #expect(visiblePixels > 100)

        let raster = try await ImageExporter.shared.render(snapshot)
        let jpeg = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions())
        #expect(!jpeg.data.isEmpty)
        #expect(jpeg.preview.width > 0 && jpeg.preview.height > 0)
    }
}
