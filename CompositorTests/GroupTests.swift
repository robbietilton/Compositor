import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
struct GroupTests {
    @Test func nestedGroupsMoveOutCollapseAndDeleteUndo() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addGroup()
        let outer = try #require(session.activeLayerID)
        session.addGroup()
        let inner = try #require(session.activeLayerID)
        session.addBlankLayer()
        let child = try #require(session.activeLayerID)
        #expect(session.activeLayer?.parentID == inner)
        #expect(!session.placeLayer(outer, in: inner))
        #expect(!session.placeLayer(inner, in: inner))
        session.toggleGroupExpansion(outer)
        #expect(session.layerRows.map { $0.layer.id } == [outer])
        #expect(session.activeLayerID == outer)
        session.toggleGroupExpansion(outer)
        #expect(session.layerRows.map(\.depth) == [0, 1, 2])
        session.selectLayer(child)
        session.moveActiveLayerOutOfGroup()
        #expect(session.activeLayer?.parentID == outer)
        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == child })?.parentID == inner)
        session.selectLayer(outer)
        session.deleteActiveLayer()
        #expect(session.document?.layers.isEmpty == true)
        session.undo()
        #expect(session.document?.layers.count == 3)
        #expect(session.document?.layers.first(where: { $0.id == child })?.parentID == inner)
    }

    @Test func hiddenParentOverridesChildrenAndExportOrderFollowsGroups() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = EditorSession()
        session.createDocument(width: 64, height: 32)
        session.addGroup()
        let group = try #require(session.activeLayerID)
        await session.importImages([url])
        let child = try #require(session.activeLayerID)
        #expect(session.activeLayer?.parentID == group)
        let source = try #require(session.activeLayer?.asset?.image)
        session.toggleLayerVisibility(group)
        #expect(session.activeLayer?.isVisible == true)
        #expect(session.document?.renderLayers.isEmpty == true)
        #expect(!session.canTransform)
        let hiddenData = try await ImageExporter.shared.pngData(try #require(session.projectSnapshot()))
        let hidden = try #require(NSBitmapImageRep(data: hiddenData))
        #expect(try #require(hidden.colorAt(x: 0, y: 0)).alphaComponent == 0)
        session.toggleLayerVisibility(group)
        #expect(session.document?.renderLayers.map(\.id) == [child])
        #expect(session.activeLayer?.asset?.image === source)
        session.selectLayer(nil)
        session.addGroup()
        let other = try #require(session.activeLayerID)
        session.addBlankLayer()
        let otherChild = try #require(session.activeLayerID)
        #expect(session.document?.renderLayers.map(\.id) == [child, otherChild])
        session.selectLayer(other)
        session.moveActiveLayer(by: -1)
        #expect(session.document?.renderLayers.map(\.id) == [otherChild, child])
        #expect(session.document?.layers.first(where: { $0.id == otherChild })?.parentID == other)
    }

    @Test func groupsRoundTripAndSurviveImageAndCanvasResize() async throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 10)
        session.addGroup()
        let group = try #require(session.activeLayerID)
        session.renameLayer(group, to: "Artwork")
        session.addBlankLayer()
        let child = try #require(session.activeLayerID)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version == 9)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Groups-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.first(where: { $0.id == group })?.isGroup == true)
        #expect(loaded.manifest.layers.first(where: { $0.id == child })?.parentID == group)
        let resized = try await ImageResizer.shared.resize(loaded, to: ImageSizeOptions(width: 40, height: 20, resolution: 72))
        let cropped = try await CanvasResizer.shared.resize(resized, to: CanvasSizeOptions(width: 30, height: 15))
        #expect(cropped.manifest.layers.first(where: { $0.id == child })?.parentID == group)
        #expect(cropped.manifest.layers.first(where: { $0.id == group })?.isGroup == true)
        var legacy = ProjectManifest(documentID: UUID(), width: 20, height: 10, activeLayerID: nil, layers: [])
        legacy.version = 1
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: legacy, images: [:]), to: url)
        #expect(try await ProjectStore.shared.load(from: url).manifest.version == 1)
    }

    @Test func malformedParentLinksAndCyclesAreRejected() throws {
        let id = UUID(), child = UUID()
        let transform = LayerTransform(origin: .zero, size: CGSize(width: 10, height: 10))
        let group = ProjectLayerRecord(id: id, name: "Group", isVisible: true, transform: transform, imageFile: nil, parentID: child, isGroup: true)
        let nested = ProjectLayerRecord(id: child, name: "Nested", isVisible: true, transform: transform, imageFile: nil, parentID: id, isGroup: true)
        #expect(throws: ProjectError.self) { try LayerHierarchy.validate([group, nested]) }
        #expect(throws: ProjectError.self) { try LayerHierarchy.validate([group]) }
        var rasterParent = group
        rasterParent.parentID = nil
        rasterParent.isGroup = false
        #expect(throws: ProjectError.self) { try LayerHierarchy.validate([rasterParent, nested]) }
    }
}
