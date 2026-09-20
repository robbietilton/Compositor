import AppKit
import Testing
@testable import Compositor

@MainActor
struct LayerTests {
    private func sessionWithThreeLayers() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600)
        for _ in 0..<3 { session.addBlankLayer() }
        return session
    }

    @Test func blankLayersAreTransparentAndInsertedAboveSelection() throws {
        let session = sessionWithThreeLayers()
        let first = try #require(session.document?.layers.first)
        session.activeLayerID = first.id
        session.addBlankLayer()
        let layers = try #require(session.document?.layers)
        #expect(layers.map(\.name) == ["Layer 1", "Layer 4", "Layer 2", "Layer 3"])
        #expect(layers[1].id == session.activeLayerID)
        #expect(layers[1].asset == nil)
        #expect(layers[1].size == CGSize(width: 800, height: 600))
        #expect(layers[1].origin == .zero)
    }

    @Test func deletionPreservesCanvasAndChoosesNeighbor() throws {
        let session = sessionWithThreeLayers()
        let layers = try #require(session.document?.layers)
        session.activeLayerID = layers[1].id
        session.deleteLayer(layers[0].id)
        #expect(session.activeLayerID == layers[1].id)
        session.deleteActiveLayer()
        #expect(session.activeLayerID == layers[2].id)
        session.deleteActiveLayer()
        #expect(session.activeLayerID == nil)
        #expect(session.document?.layers.isEmpty == true)
        #expect(session.document?.size == CGSize(width: 800, height: 600))
        session.addBlankLayer()
        #expect(session.document?.layers.count == 1)
    }

    @Test func renameAndVisibilityKeepIdentity() throws {
        let session = sessionWithThreeLayers()
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "  Foreground \n")
        session.renameLayer(id, to: " \n ")
        #expect(session.activeLayer?.name == "Foreground")
        session.toggleLayerVisibility(id)
        #expect(session.activeLayer?.isVisible == false)
        #expect(session.activeLayerID == id)
        session.toggleLayerVisibility(id)
        #expect(session.activeLayer?.isVisible == true)
    }

    @Test func reorderTranslatesVisibleOrderAndKeepsSelection() throws {
        let session = sessionWithThreeLayers()
        let active = session.activeLayerID
        session.reorderLayers(from: IndexSet(integer: 0), to: 3)
        #expect(session.document?.layers.map(\.name) == ["Layer 3", "Layer 1", "Layer 2"])
        #expect(session.activeLayerID == active)
        #expect(!session.canMoveActiveLayer(by: -1))
        session.moveActiveLayer(by: 1)
        #expect(session.document?.layers.map(\.name) == ["Layer 1", "Layer 3", "Layer 2"])
        session.reorderLayers(from: IndexSet(integer: 99), to: 0)
        #expect(session.document?.layers.count == 3)
    }

    @Test func unavailableActionsDoNotChangeDocument() {
        let session = EditorSession()
        session.addBlankLayer()
        #expect(session.document == nil)
        session.createDocument(width: 30_000, height: 30_000)
        session.addBlankLayer()
        #expect(session.activeLayer?.asset == nil)
        session.isImporting = true
        session.addBlankLayer()
        session.deleteActiveLayer()
        #expect(session.document?.layers.count == 1)
    }

    @Test func nativeSelectionDoesNotReloadRowsAndReorderKeepsIdentity() throws {
        final class CountingTable: NSTableView {
            var reloadCount = 0
            override func reloadData() { reloadCount += 1; super.reloadData() }
            override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
                reloadCount += 1
                super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
            }
        }
        let session = sessionWithThreeLayers()
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = CountingTable()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.update(table)
        let reloads = table.reloadCount
        let bottom = try #require(session.document?.layers.first?.id)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(session.activeLayerID == bottom) // Synchronous delegate, no click timer.
        coordinator.update(table)
        #expect(table.reloadCount == reloads)
        #expect(session.placeLayer(bottom, in: nil))
        coordinator.update(table)
        #expect(table.selectedRow == 0)
        #expect(session.document?.layers.last?.id == bottom)
        #expect(session.placeLayer(bottom, in: nil, atBottom: true))
        coordinator.update(table)
        #expect(table.selectedRow == 2)
        #expect(session.document?.layers.first?.id == bottom)
        #expect(!session.placeLayer(UUID(), in: nil))
        session.isImporting = true
        #expect(!session.placeLayer(bottom, in: nil))
    }

    @Test func selectionAndRenameDoNotInvalidateCanvasButPixelChangesDo() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        let asset = ImportedImage(image: image, thumbnail: image, name: "Test")
        session.insert(asset)
        session.insert(asset)
        let view = CanvasView(session: session)
        #expect(view.synchronizeDisplay())
        let first = try #require(session.document?.layers.first?.id)
        session.activeLayerID = first
        session.renameLayer(first, to: "Renamed")
        #expect(!view.synchronizeDisplay())
        session.moveActiveLayer(by: 1)
        #expect(view.synchronizeDisplay())
        session.toggleLayerVisibility(first)
        #expect(view.synchronizeDisplay())
        session.zoom(to: 2)
        #expect(view.synchronizeDisplay())
    }

    @Test func compositingHonorsVisibilityOrderAndBlankLayers() throws {
        func asset(_ color: CGColor, name: String) throws -> ImportedImage {
            let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(ctx.makeImage())
            return ImportedImage(image: image, thumbnail: image, name: name)
        }
        let session = EditorSession()
        session.insert(try asset(CGColor(red: 1, green: 0, blue: 0, alpha: 1), name: "Red"))
        session.insert(try asset(CGColor(red: 0, green: 0, blue: 1, alpha: 1), name: "Blue"))
        let blueID = try #require(session.activeLayerID)
        session.viewport.resize(to: CGSize(width: 8, height: 8), backingScale: 1, documentSize: session.document?.size)
        session.zoom(to: 1)
        let view = CanvasView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        func centerPixel() throws -> NSColor {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(view.bounds)
            return try #require(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        }
        #expect(try centerPixel().blueComponent > 0.95)
        session.toggleLayerVisibility(blueID)
        #expect(try centerPixel().redComponent > 0.95)
        session.toggleLayerVisibility(blueID)
        session.moveActiveLayer(by: -1)
        #expect(try centerPixel().redComponent > 0.95)
        session.activeLayerID = session.document?.layers.last?.id
        session.addBlankLayer()
        #expect(try centerPixel().redComponent > 0.95)
        session.deleteLayer(session.document!.layers[1].id)
        #expect(try centerPixel().blueComponent > 0.95)
    }

    @Test func newCanvasStartsWithOneSelectedEmptyLayer() {
        let session = EditorSession()
        session.createNewProject(width: 640, height: 480)
        #expect(session.document?.layers.count == 1)
        #expect(session.activeLayer?.name == "Layer 1" && session.activeLayer?.asset == nil)
        #expect(session.activeLayer?.size == CGSize(width: 640, height: 480))
        #expect(session.canPaint)
    }

    /// Several selected layers, a folder with its contents among them, all go with one Delete in one undo step.
    @Test func deletingAMultiSelectionRemovesEveryLayerInOneStep() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        session.addBlankLayer()
        let keep = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addGroup()
        let folder = try #require(session.activeLayerID)
        session.addBlankLayer() // inside the folder
        let child = try #require(session.activeLayerID)
        session.selectLayer(nil)
        session.addBlankLayer()
        let top = try #require(session.activeLayerID)
        #expect(session.document?.layers.first { $0.id == child }?.parentID == folder)
        let before = session.document
        let count = session.history.undoCount
        session.selectLayers([folder, top], primary: top)

        session.deleteLayerOrMask()
        #expect(session.document?.layers.map(\.id) == [keep], "the folder, its child and the other selected layer are gone")
        #expect(session.history.undoCount == count + 1 && session.history.undoName == "Delete Layers")
        #expect(session.activeLayerID == keep && session.selectedLayerIDs == [keep])
        session.undo()
        #expect(session.document == before)

        session.selectLayers([keep], primary: keep)
        session.deleteLayerOrMask() // a single selection still deletes just that layer
        #expect(session.document?.layers.contains { $0.id == keep } == false && session.history.undoName == "Delete Layer")
    }

    /// Option-dragging a layer in the Layers panel drops a duplicate where it lands, as one undo step.
    @Test func duplicatingALayerByDraggingPlacesTheCopyAsOneStep() throws {
        let session = sessionWithThreeLayers()
        let rows = session.layerRows.map(\.layer) // as the panel lists them, top first
        let top = try #require(rows.first), bottom = try #require(rows.last)
        let before = session.document
        let count = session.history.undoCount
        #expect(session.duplicateLayer(bottom.id, in: nil, above: top.id))
        let after = session.layerRows.map(\.layer)
        #expect(after.count == 4)
        #expect(session.history.undoCount == count + 1)
        #expect(session.history.undoName == "Duplicate Layer")
        #expect(after.first?.name == "\(bottom.name) copy", "the copy lands above the top layer: \(after.map(\.name))")
        #expect(after.contains { $0.id == bottom.id }, "the original stays where it was")
        session.undo()
        #expect(session.document == before)

        session.addGroup()
        let folder = try #require(session.activeLayerID)
        #expect(!session.duplicateLayer(folder, in: nil, atBottom: true), "folders aren't duplicated this way")
    }
}
