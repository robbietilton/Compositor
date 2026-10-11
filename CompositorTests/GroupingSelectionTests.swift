import Foundation
import Testing
@testable import Compositor

@MainActor
struct GroupingSelectionTests {
    @Test func singleLayerAndFolderAreWrappedRatherThanCreatingAChildFolder() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let layer = try #require(session.activeLayerID)
        session.groupSelectedLayers()
        let inner = try #require(session.activeLayerID)
        #expect(session.document?.layers.first(where: { $0.id == layer })?.parentID == inner)
        session.groupSelectedLayers()
        let outer = try #require(session.activeLayerID)
        #expect(session.document?.layers.first(where: { $0.id == inner })?.parentID == outer)
        #expect(session.document?.layers.first(where: { $0.id == layer })?.parentID == inner)
        #expect(session.activeLayer?.parentID == nil)
        session.undo()
        #expect(session.document?.layers.first(where: { $0.id == inner })?.parentID == nil)
        #expect(session.document?.layers.count == 2)
    }
    @Test func multipleSelectionPreservesOrderAndSelectedFolderDescendants() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.addBlankLayer()
        let child = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addBlankLayer()
        let sibling = try #require(session.activeLayerID)
        let before = session.document
        session.selectLayers([folder, child, sibling], primary: sibling)
        #expect(session.selectedLayerIDs.count == 3)
        #expect(!session.canTransform)
        session.groupSelectedLayers()
        let wrapper = try #require(session.activeLayerID)
        #expect(session.document?.layers.first(where: { $0.id == folder })?.parentID == wrapper)
        #expect(session.document?.layers.first(where: { $0.id == sibling })?.parentID == wrapper)
        #expect(session.document?.layers.first(where: { $0.id == child })?.parentID == folder)
        #expect(session.document?.renderLayers.map(\.id) == [child, sibling])
        #expect(session.selectedLayerIDs == [wrapper])
        session.undo()
        #expect(session.document == before)
        session.redo()
        #expect(session.document?.layers.count == 4)
    }
    @Test func itemsFromDifferentFoldersUseCommonParentAndEmptySelectionCreatesEmptyGroup() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.groupSelectedLayers()
        let first = try #require(session.activeLayerID)
        session.addBlankLayer()
        let a = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.groupSelectedLayers()
        let second = try #require(session.activeLayerID)
        session.addBlankLayer()
        let b = try #require(session.activeLayerID)
        session.selectLayers([a, b], primary: b)
        session.groupSelectedLayers()
        let group = try #require(session.activeLayerID)
        #expect(session.activeLayer?.parentID == nil)
        #expect(session.document?.layers.first(where: { $0.id == a })?.parentID == group)
        #expect(session.document?.layers.first(where: { $0.id == b })?.parentID == group)
        #expect(session.document?.layers.first(where: { $0.id == first })?.parentID == nil)
        #expect(session.document?.layers.first(where: { $0.id == second })?.parentID == nil)
    }
}
