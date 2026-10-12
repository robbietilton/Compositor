import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerAlignTests {
    /// A 400 × 300 canvas with a solid layer for each of `rects`, bottom to top.
    private func session(_ rects: [CGRect]) throws -> (EditorSession, [UUID]) {
        let session = EditorSession()
        session.createDocument(width: 400, height: 300)
        var ids: [UUID] = []
        for rect in rects {
            let context = try BrushRaster.context(width: Int(rect.width), height: Int(rect.height), mask: false)
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: rect.size))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Box"), centeredAt: CGPoint(x: rect.midX, y: rect.midY))
            ids.append(try #require(session.activeLayerID))
        }
        return (session, ids)
    }

    private func origins(_ session: EditorSession, _ ids: [UUID]) -> [CGPoint] {
        ids.compactMap { id in session.document?.layers.first { $0.id == id }?.transform.origin }
    }

    @Test func severalLayersAlignToEachOther() throws {
        let (session, ids) = try session([CGRect(x: 10, y: 20, width: 40, height: 30),
                                          CGRect(x: 100, y: 60, width: 60, height: 20),
                                          CGRect(x: 200, y: 10, width: 20, height: 50)])
        session.selectedLayerIDs = Set(ids)
        session.alignLayers(.left)
        #expect(origins(session, ids).map(\.x) == [10, 10, 10])
        session.alignLayers(.bottom)
        #expect(origins(session, ids).map(\.y) == [50, 60, 30])
        session.undo()
        #expect(origins(session, ids).map(\.y) == [20, 60, 10])
    }

    @Test func oneLayerAlignsToTheCanvasAndTheSelectionComesFirst() throws {
        let (session, ids) = try session([CGRect(x: 10, y: 10, width: 101, height: 60)])
        session.selectedLayerIDs = Set(ids)
        session.alignLayers(.horizontalCenter)
        // 400 − 101 leaves an odd 299 to share: the layer lands on a whole pixel, not between two.
        #expect(origins(session, ids).first?.x == 150)
        session.alignLayers(.verticalCenter)
        #expect(origins(session, ids).first?.y == 120)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 300, y: 0, width: 50, height: 50), transform: nil))
        session.alignLayers(.right)
        #expect(origins(session, ids).first?.x == 249)
    }

    @Test func aSelectedFolderMovesAsOne() throws {
        let (session, ids) = try session([CGRect(x: 50, y: 10, width: 20, height: 20),
                                          CGRect(x: 90, y: 40, width: 20, height: 20),
                                          CGRect(x: 200, y: 100, width: 20, height: 20)])
        session.selectedLayerIDs = [ids[0], ids[1]]
        session.groupSelectedLayers()
        let folder = try #require(session.activeLayerID)
        session.selectedLayerIDs = [folder, ids[2]]
        session.alignLayers(.left)
        // The folder's box already starts furthest left; its layers keep their spacing, and the third joins them.
        #expect(origins(session, ids).map(\.x) == [50, 90, 50])
    }

    @Test func distributeSpreadsMiddlesOrGapsEvenly() {
        let boxes = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 60, y: 0, width: 30, height: 10),
                     CGRect(x: 100, y: 0, width: 10, height: 10)]
        // Middles at 5, 75 and 105: the middle one moves to 55.
        #expect(LayerDistribution.horizontalCenters.offsets(of: boxes).map(\.width) == [0, -20, 0])
        // 110 across, 50 of it boxes: gaps of 30 put the middle one at 40.
        #expect(LayerDistribution.horizontalSpacing.offsets(of: boxes).map(\.width) == [0, -20, 0])
        let uneven = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 70, width: 10, height: 10),
                      CGRect(x: 0, y: 20, width: 10, height: 40), CGRect(x: 0, y: 100, width: 10, height: 10)]
        // Order follows position, not the list: gaps of (110 − 70) / 3.
        let gap: CGFloat = 40 / 3
        let spaced = LayerDistribution.verticalSpacing.offsets(of: uneven).map(\.height)
        #expect(abs(spaced[2] - (10 + gap - 20)) < 0.001)
        #expect(abs(spaced[1] - (10 + gap + 40 + gap - 70)) < 0.001)
        #expect(spaced[0] == 0 && spaced[3] == 0)
    }

    @Test func distributeNeedsThreeAndMovesWholePixels() throws {
        let (session, ids) = try session([CGRect(x: 0, y: 0, width: 10, height: 10),
                                          CGRect(x: 50, y: 0, width: 10, height: 10),
                                          CGRect(x: 101, y: 0, width: 10, height: 10)])
        session.selectedLayerIDs = [ids[0], ids[1]]
        session.distributeLayers(.horizontalCenters)
        #expect(origins(session, ids).map(\.x) == [0, 50, 101])
        session.selectedLayerIDs = Set(ids)
        session.distributeLayers(.horizontalCenters)
        #expect(origins(session, ids).map(\.x) == [0, 51, 101])
    }
}