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
        #expect(snapshot.manifest.version == 12)
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

    @Test func ungroupLayersRestoresChildrenAtTheFoldersSpotAndUndoes() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let below = try #require(session.activeLayerID)
        #expect(!session.canUngroupLayers, "a plain layer has nothing to unwrap")
        session.addGroup()
        let group = try #require(session.activeLayerID)
        session.addBlankLayer()
        let childA = try #require(session.activeLayerID)
        session.addBlankLayer()
        let childB = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addBlankLayer()
        let above = try #require(session.activeLayerID)
        #expect(session.document?.layers.map(\.parentID) == [nil, nil, group, group, nil])

        session.selectLayer(group)
        #expect(session.canUngroupLayers)
        let undoCount = session.history.undoCount
        session.ungroupLayers()
        let layers = try #require(session.document?.layers)
        #expect(!layers.contains { $0.id == group }, "the folder itself goes")
        #expect(layers.first { $0.id == childA }?.parentID == nil)
        #expect(layers.first { $0.id == childB }?.parentID == nil)
        // Spliced in where the folder sat: below stays below both children, above stays above both.
        let order = layers.map(\.id)
        #expect(order.firstIndex(of: below)! < order.firstIndex(of: childA)!)
        #expect(order.firstIndex(of: childA)! < order.firstIndex(of: childB)!)
        #expect(order.firstIndex(of: childB)! < order.firstIndex(of: above)!)
        #expect(session.selectedLayerIDs == [childA, childB])
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Ungroup Layers")

        session.undo()
        #expect(session.document?.layers.first { $0.id == childA }?.parentID == group)
        #expect(session.document?.layers.first { $0.id == group }?.isGroup == true)
        session.redo()
        #expect(session.document?.layers.count == 4)
    }

    @Test func ungroupPreservesClippingBetweenTwoOfAFoldersOwnChildren() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let base = try #require(session.activeLayerID)
        session.addBlankLayer()
        let clipped = try #require(session.activeLayerID)
        session.linkMask(source: base, target: clipped)
        session.selectLayers([base, clipped], primary: base)
        session.groupSelectedLayers()
        let group = try #require(session.activeLayerID)

        session.ungroupLayers()
        // Spliced in together at the folder's old spot, so the pair stays adjacent.
        #expect(session.document?.layers.first { $0.id == clipped }?.maskSourceID == base)
    }

    @Test func ungroupingReleasesClippingThatNoLongerMakesSense() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let outsideBase = try #require(session.activeLayerID)
        session.addBlankLayer()
        let between = try #require(session.activeLayerID)
        session.addBlankLayer()
        let childSource = try #require(session.activeLayerID)
        // A clip can be set up across a folder boundary — `linkMask` doesn't forbid it — even though the two
        // layers aren't really adjacent once the folder is in between.
        session.linkMask(source: outsideBase, target: childSource)
        session.selectLayer(childSource)
        session.groupSelectedLayers()
        let group = try #require(session.activeLayerID)
        #expect(session.document?.layers.map(\.id) == [outsideBase, between, group, childSource])

        session.ungroupLayers()
        // Ungrouped, `childSource` lands right after `between` — no longer next to its base — so the clip goes.
        #expect(session.document?.layers.map(\.id) == [outsideBase, between, childSource])
        #expect(session.document?.layers.first { $0.id == childSource }?.maskSourceID == nil)
    }
}
