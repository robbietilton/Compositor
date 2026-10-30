import AppKit
import Testing
@testable import Compositor

@MainActor
struct PerspectiveCropTests {
    /// A square in four colors: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func quadrants(_ side: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: side, height: side, mask: false)
        let half = CGFloat(side) / 2
        for (color, origin) in [((1.0, 0.0, 0.0), CGPoint(x: 0, y: 0)), ((0.0, 1.0, 0.0), CGPoint(x: half, y: 0)),
                                ((0.0, 0.0, 1.0), CGPoint(x: 0, y: half)), ((1.0, 1.0, 1.0), CGPoint(x: half, y: half))] {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(origin: origin, size: CGSize(width: half, height: half)))
        }
        return try #require(context.makeImage())
    }

    /// The pixel at `x`, `y` from the top-left, as 0–255 red, green, blue and alpha.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    @Test func sizeIsTheMeanOfOppositeSidesAndMirroredOrFoldedShapesAreRefused() {
        let rect = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 60), CGPoint(x: 10, y: 60)]
        #expect(PerspectiveCrop.size(of: rect) == CGSize(width: 100, height: 50))
        let trapezoid = [CGPoint(x: 30, y: 0), CGPoint(x: 70, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]
        // Top 40 and bottom 100 make 70; each side is hypot(30, 50), about 58.3.
        #expect(PerspectiveCrop.size(of: trapezoid) == CGSize(width: 70, height: 58))
        #expect(PerspectiveCrop.size(of: [rect[1], rect[0], rect[3], rect[2]]) == nil)
        #expect(PerspectiveCrop.size(of: [rect[0], rect[2], rect[1], rect[3]]) == nil)
    }

    @Test func aSquarePhotographedAtAnAngleComesOutUpright() async throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 160)
        let shape = [CGPoint(x: 60, y: 20), CGPoint(x: 140, y: 30), CGPoint(x: 170, y: 140), CGPoint(x: 30, y: 130)]
        let square = try quadrants(100)
        let tilted = try DistortWarp.warp(square, transform: LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100)),
                                          corners: shape, isMask: false)
        session.insert(ImportedImage(image: tilted.image, thumbnail: tilted.image, name: "Tilted"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform = tilted.transform
        let original = try #require(session.document)

        session.selectTool(.crop)
        session.setCropPerspective(true)
        session.setCropCorners(shape)
        let size = try #require(PerspectiveCrop.size(of: shape))
        await session.commitCrop()
        #expect(session.cropError == nil)
        #expect(session.document?.width == Int(size.width) && session.document?.height == Int(size.height))
        #expect(session.cropCorners == nil && session.cropRect == nil)
        let layer = try #require(session.document?.layers.first)
        let image = try #require(layer.asset?.image)
        // Trimmed to what's visible, which is the whole upright square.
        #expect(layer.transform.origin == .zero && layer.transform.size == size)
        let width = image.width, height = image.height
        let red = try pixel(image, width / 4, height / 4), green = try pixel(image, width * 3 / 4, height / 4)
        let blue = try pixel(image, width / 4, height * 3 / 4), white = try pixel(image, width * 3 / 4, height * 3 / 4)
        #expect(red[0] > 230 && red[1] < 25 && red[2] < 25, "\(red)")
        #expect(green[1] > 230 && green[0] < 25 && green[2] < 25, "\(green)")
        #expect(blue[2] > 230 && blue[0] < 25 && blue[1] < 25, "\(blue)")
        #expect(white.allSatisfy { $0 > 230 }, "\(white)")
        // The shape's corners reach the image's corners: stretching its bounds instead would leave them empty.
        for (x, y, channel) in [(3, 3, 0), (width - 4, 3, 1), (3, height - 4, 2), (width - 4, height - 4, 0)] {
            let corner = try pixel(image, x, y)
            #expect(corner[3] > 230 && corner[channel] > 230, "\(x), \(y): \(corner)")
        }

        session.undo()
        #expect(session.document == original)
    }

    @Test func linkedMasksCropWithTheirLayerAndFoldersCoverTheNewCanvas() throws {
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: 100, height: 100))
        let red = try #require(try BrushRaster.context(width: 40, height: 40, mask: false).then {
            $0.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.makeImage())
        // White on its left half, black on its right.
        let half = try #require(try BrushRaster.context(width: 40, height: 40, mask: true).then {
            $0.setFillColor(gray: 1, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }.makeImage())
        let layerID = UUID(), folderID = UUID()
        let manifest = ProjectManifest(documentID: UUID(), width: 100, height: 100, activeLayerID: layerID, layers: [
            ProjectLayerRecord(id: folderID, name: "Folder", isVisible: true, transform: canvas, imageFile: nil, isGroup: true),
            ProjectLayerRecord(id: layerID, name: "Red", isVisible: true,
                               transform: LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 40)),
                               imageFile: "red.png", parentID: folderID, maskFile: "red.mask.png", maskEnabled: true),
        ])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [layerID: ImportedImage(image: red, thumbnail: red, name: "Red")],
                                       masks: [layerID: try LayerMask.asset(from: half)])
        let corners = [CGPoint(x: 5, y: 5), CGPoint(x: 85, y: 5), CGPoint(x: 85, y: 85), CGPoint(x: 5, y: 85)]
        let result = try PerspectiveCrop.crop(snapshot, corners: corners)
        #expect(result.manifest.width == 80 && result.manifest.height == 80)
        let folder = try #require(result.manifest.layers.first { $0.id == folderID })
        #expect(folder.transform == LayerTransform(origin: .zero, size: CGSize(width: 80, height: 80)))
        let layer = try #require(result.manifest.layers.first { $0.id == layerID })
        #expect(layer.transform.origin == CGPoint(x: 5, y: 5) && layer.transform.size == CGSize(width: 40, height: 40))
        #expect(layer.maskPlacement == nil && layer.parentID == folderID)
        let mask = try #require(result.masks[layerID]?.image)
        #expect(mask.width == 40 && mask.height == 40)
        #expect(try pixel(mask, 5, 20)[0] > 230 && pixel(mask, 35, 20)[0] < 25)
    }

    @Test func animatedLayersAreRefusedRatherThanFlattened() throws {
        let id = UUID()
        let image = try quadrants(4)
        let manifest = ProjectManifest(documentID: UUID(), width: 4, height: 4, activeLayerID: id, layers: [
            ProjectLayerRecord(id: id, name: "GIF", isVisible: true, transform: LayerTransform(origin: .zero, size: CGSize(width: 4, height: 4)),
                               imageFile: "gif.png", gif: ProjectGIFRecord(sourceFile: "gif.gif", selectedFrameIndex: 0)),
        ])
        let snapshot = ProjectSnapshot(manifest: manifest, images: [id: ImportedImage(image: image, thumbnail: image, name: "GIF")])
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 3), CGPoint(x: 0, y: 4)]
        #expect(throws: PerspectiveCrop.Failure.self) { try PerspectiveCrop.crop(snapshot, corners: corners) }
    }

    @Test func turningPerspectiveOffKeepsTheCornersBoundsAsTheFrame() {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        session.selectTool(.crop)
        session.setCropPerspective(true)
        #expect(session.visibleCropCorners?.count == 4)
        session.setCropCorners([CGPoint(x: 20, y: 10), CGPoint(x: 150, y: 5), CGPoint(x: 180, y: 90), CGPoint(x: 10.5, y: 80)])
        #expect(session.cropRect == CGRect(x: 10.5, y: 5, width: 169.5, height: 85))
        // A mirrored shape is ignored.
        session.setCropCorners([CGPoint(x: 150, y: 5), CGPoint(x: 20, y: 10), CGPoint(x: 10, y: 80), CGPoint(x: 180, y: 90)])
        #expect(session.cropCorners?.first == CGPoint(x: 20, y: 10))
        session.setCropPerspective(false)
        #expect(session.cropCorners == nil && session.visibleCropCorners == nil)
        #expect(session.cropRect == CGRect(x: 11, y: 5, width: 169, height: 85))
    }
}

private extension CGContext {
    func then(_ body: (CGContext) -> Void) -> CGContext { body(self); return self }
}
