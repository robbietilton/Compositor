import AppKit
import ImageIO
import Testing
@testable import Compositor

@MainActor
struct LayerExportTests {
    private func solid(_ color: CGColor, alpha: CGFloat = 1) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.copy(alpha: alpha)!)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
    }

    private func record(_ id: UUID, _ name: String, visible: Bool = true, at origin: CGPoint, _ size: CGSize,
                        parent: UUID? = nil, opacity: Double? = nil, clippedTo source: UUID? = nil) -> ProjectLayerRecord {
        var record = ProjectLayerRecord(id: id, name: name, isVisible: visible,
            transform: LayerTransform(origin: origin, size: size, sampling: .nearest), imageFile: "\(id).png")
        record.parentID = parent
        record.opacity = opacity
        record.maskSourceID = source
        return record
    }

    private func decoded(_ data: Data?) throws -> NSBitmapImageRep {
        let data = try #require(data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return NSBitmapImageRep(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    @Test func eachLayerExportsOnItsOwnTrimmedToItsPixels() async throws {
        let red = UUID(), blue = UUID(), folder = UUID(), empty = UUID(), clipped = UUID()
        var folderRecord = ProjectLayerRecord(id: folder, name: "Folder", isVisible: true,
            transform: LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10)), imageFile: nil)
        folderRecord.isGroup = true
        folderRecord.opacity = 0.5
        let images = [
            red: ImportedImage(image: try solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1)), thumbnail: try solid(.black), name: "Red"),
            blue: ImportedImage(image: try solid(CGColor(red: 0, green: 0, blue: 1, alpha: 1)), thumbnail: try solid(.black), name: "Blue"),
            empty: ImportedImage(image: try solid(.black, alpha: 0), thumbnail: try solid(.black), name: "Empty"),
            clipped: ImportedImage(image: try solid(CGColor(red: 0, green: 1, blue: 0, alpha: 1)), thumbnail: try solid(.black), name: "Green"),
        ]
        let snapshot = ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: 10, height: 10, activeLayerID: red, layers: [
            record(red, "Red", at: CGPoint(x: 1, y: 1), CGSize(width: 2, height: 3)),
            // Green over the left half of Red, clipped to it: part of how Red looks.
            record(clipped, "Green", at: CGPoint(x: 0, y: 0), CGSize(width: 2, height: 10), clippedTo: red),
            record(empty, "Empty", at: .zero, CGSize(width: 10, height: 10)),
            folderRecord,
            // Hidden, in a folder at 50%, over Red.
            record(blue, "Blue", visible: false, at: CGPoint(x: 0, y: 2), CGSize(width: 6, height: 1), parent: folder),
        ]), images: images)

        let redPNG = try decoded(await ImageExporter.shared.layerPNGData(snapshot, layer: red))
        #expect(redPNG.pixelsWide == 2 && redPNG.pixelsHigh == 3, "trimmed to Red, without Blue over it")
        let left = try #require(redPNG.colorAt(x: 0, y: 1)), right = try #require(redPNG.colorAt(x: 1, y: 1))
        #expect(left.greenComponent > 0.9 && left.redComponent < 0.05, "the layer clipped to it comes too")
        #expect(right.redComponent > 0.95 && right.greenComponent < 0.2 && right.alphaComponent == 1)

        let bluePNG = try decoded(await ImageExporter.shared.layerPNGData(snapshot, layer: blue))
        #expect(bluePNG.pixelsWide == 6 && bluePNG.pixelsHigh == 1, "hidden, it still exports, and Red doesn't")
        let pixel = try #require(bluePNG.colorAt(x: 3, y: 0))
        #expect(pixel.blueComponent > 0.95 && abs(pixel.alphaComponent - 0.5) < 0.02, "its folder's opacity applies")

        #expect(try await ImageExporter.shared.layerPNGData(snapshot, layer: folder) == nil,
                "a folder exports what's in it as shown or hidden there, and Blue is hidden")

        #expect(try await ImageExporter.shared.layerPNGData(snapshot, layer: empty) == nil, "nothing to export")
    }

    @Test func layerNamesBecomeFileNames() {
        #expect(ProjectController.fileName("Logo / Dark: v2") == "Logo - Dark- v2")
        #expect(ProjectController.fileName("  ") == "Layer")
        #expect(ProjectController.fileName(".hidden") == "Layer.hidden")
    }
}
