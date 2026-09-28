import AppKit
import Testing
@testable import Compositor

/// The Layers panel's commands with folders, selections and masks around them.
@MainActor
struct LayerCommandTests {
    /// A 100×100 document with a solid layer named `name` for each entry, bottom to top.
    private func session(_ names: [String]) throws -> (EditorSession, [String: UUID]) {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        var ids: [String: UUID] = [:]
        for name in names {
            let context = try BrushRaster.context(width: 100, height: 100, mask: false)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: name))
            ids[name] = try #require(session.activeLayerID)
        }
        return (session, ids)
    }

    /// Merge Visible puts the merged layer where the visible stack was, even when part of it sits in a folder.
    @Test func mergeVisibleKeepsTheStackOrderAroundFolders() throws {
        let (session, id) = try session(["B", "A1", "A2", "T"])
        session.selectLayers([id["A1"]!, id["A2"]!], primary: id["A2"])
        session.groupSelectedLayers()
        session.toggleLayerVisibility(id["T"]!)
        session.mergeVisible()
        session.toggleLayerVisibility(id["T"]!)
        #expect(session.document?.renderLayers.map(\.name) == ["A2", "T"], "T was on top and stays there")
    }

    /// Soloing a layer inside a folder leaves the folder showing, or the layer itself would disappear.
    @Test func hidingOtherLayersKeepsTheFolderAroundTheLayer() throws {
        let (session, id) = try session(["C", "A"])
        session.selectLayers([id["A"]!], primary: id["A"])
        session.groupSelectedLayers()
        session.toggleOtherLayersVisibility(id["A"]!)
        let visible = try #require(session.document?.effectiveVisibleIDs)
        #expect(visible.contains(id["A"]!) && !visible.contains(id["C"]!))
        session.toggleOtherLayersVisibility(id["A"]!)
        #expect(session.document?.effectiveVisibleIDs.contains(id["C"]!) == true)
    }

    /// Applying the mask targets the layer's pixels again: the mask it targeted is gone.
    @Test func applyingTheMaskTargetsThePixels() throws {
        let (session, _) = try session(["A"])
        session.addLayerMask(revealing: true)
        #expect(session.isMaskSelected)
        session.applyLayerMask()
        #expect(session.activeLayer?.mask == nil && !session.isMaskSelected && session.canPaint)
    }

    /// Intersecting with pixels that the selection doesn't reach leaves nothing selected, not an empty selection.
    @Test func intersectingWithNothingDeselects() throws {
        let (session, id) = try session(["A"])
        let index = try #require(session.document?.layers.firstIndex { $0.id == id["A"] })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 60, y: 60), size: CGSize(width: 40, height: 40))
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 30, height: 30), transform: nil), mode: .replace, name: "Select")
        session.intersectLayerSelection(layerID: id["A"]!)
        #expect(session.selection == nil)
    }

    /// Copy Layer Style in one document pastes in another, as Photoshop's does.
    @Test func copiedStyleReachesOtherDocuments() throws {
        let (first, _) = try session(["A"])
        var effects = LayerEffects()
        effects.shadow = ShadowEffect()
        first.setEffects(effects, name: "Add Drop Shadow")
        first.copyLayerStyle()
        let (second, _) = try session(["B"])
        #expect(second.canPasteLayerStyle)
        second.pasteLayerStyle()
        #expect(second.activeLayer?.effects?.shadow != nil)
    }
}
