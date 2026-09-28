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
        #expect(!session.placeLayer(bottom, in: nil, above: UUID()))
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
        // Folder duplication arrived in 1.1.5: a dragged folder copies itself and its contents.
        #expect(session.duplicateLayer(folder, in: nil, atBottom: true), "a folder duplicates with its contents")
    }

    private func makeLayerTable(session: EditorSession) -> (LayerTableView, NativeLayerList.Coordinator, NSWindow) {
        let coordinator = NativeLayerList.Coordinator(session: session)
        let table = LayerTableView()
        table.session = session
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 252
        table.addTableColumn(column)
        table.delegate = coordinator
        table.dataSource = coordinator
        coordinator.update(table)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 252, height: 400))
        scroll.documentView = table
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 252, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.update(table)
        return (table, coordinator, window)
    }

    @Test func testContextMenuContainsCoreLayerActions() throws {
        let session = sessionWithThreeLayers()
        let (_, coordinator, _) = makeLayerTable(session: session)

        let menu = try #require(coordinator.contextMenu(for: 0))
        let titles = menu.items.map(\.title)

        #expect(titles.contains("Duplicate Layer"))
        #expect(titles.contains("Delete Layer"))
        #expect(titles.contains("Rename…"))
        #expect(titles.contains("Group from Layers"))
        #expect(titles.contains("Ungroup Layers"))
        #expect(titles.contains("Move Out of Folder"))
        #expect(titles.contains("Select Pixels"))
        // Mask actions
        let addMaskItem = try #require(menu.items.first(where: { $0.title == "Add Mask" }))
        let submenu = try #require(addMaskItem.submenu)
        let subTitles = submenu.items.map(\.title)
        #expect(subTitles == ["Reveal All", "Hide All"], "no selection, so Reveal/Hide Selection are left out entirely")
        #expect(titles.contains("Disable Layer Mask"))
        #expect(titles.contains("Apply Layer Mask"))
        #expect(titles.contains("Delete Layer Mask"))
        #expect(titles.contains("Link Mask") || titles.contains("Unlink Mask"))
        #expect(titles.contains("Copy Layer Style"))
        #expect(titles.contains("Paste Layer Style"))
        #expect(titles.contains("Clear Layer Style"))
        #expect(titles.contains(session.mergeTitle))
        #expect(titles.contains("Merge Visible"))
        #expect(titles.contains("Flatten Image"))
        #expect(titles.contains("Hide Layer") || titles.contains("Show Layer"))
        #expect(titles.contains("Hide All Other Layers") || titles.contains("Show All Other Layers"))
        // Order: separators split the menu into the sections the spec lists, in order.
        let sectionStarts = ["Duplicate Layer", "Group from Layers", "Select Pixels", "Add Mask", "Create Clipping Mask",
                             "Copy Layer Style", session.mergeTitle, "Hide Layer"]
        var remaining = titles
        for start in sectionStarts {
            let index = try #require(remaining.firstIndex(of: start))
            remaining.removeFirst(index + 1)
        }
    }

    @Test func testRightClickOnUnselectedLayerSelectsIt() throws {
        let session = sessionWithThreeLayers()
        let layers = session.layerRows.map(\.layer)
        let layerA = layers[0]
        let layerB = layers[1]
        session.selectLayers([layerA.id], primary: layerA.id)
        #expect(session.activeLayerID == layerA.id)
        #expect(session.selectedLayerIDs == [layerA.id])

        let (table, coordinator, window) = makeLayerTable(session: session)
        coordinator.update(table)

        let row1Rect = table.rect(ofRow: 1)
        let tablePoint = NSPoint(x: row1Rect.midX, y: row1Rect.midY)
        let windowPoint = table.convert(tablePoint, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))

        let menu = table.menu(for: event)
        #expect(menu != nil)
        #expect(session.selectedLayerIDs == [layerB.id])
        #expect(session.activeLayerID == layerB.id)
    }

    @Test func testRightClickInsideMultiSelectionPreservesSelection() throws {
        let session = sessionWithThreeLayers()
        let layers = session.layerRows.map(\.layer)
        let layerA = layers[0]
        let layerB = layers[1]
        let layerC = layers[2]
        let allIDs: Set<UUID> = [layerA.id, layerB.id, layerC.id]
        session.selectLayers(allIDs, primary: layerA.id)

        let (table, coordinator, window) = makeLayerTable(session: session)
        coordinator.update(table)

        let row1Rect = table.rect(ofRow: 1)
        let tablePoint = NSPoint(x: row1Rect.midX, y: row1Rect.midY)
        let windowPoint = table.convert(tablePoint, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))

        let menu = table.menu(for: event)
        #expect(menu != nil)
        #expect(session.selectedLayerIDs == allIDs)
        #expect(session.activeLayerID == layerB.id)
    }

    @Test func testRightClickOutsideRowsReturnsNoMenu() throws {
        let session = sessionWithThreeLayers()
        let initialSelection = session.selectedLayerIDs
        let (table, coordinator, window) = makeLayerTable(session: session)
        coordinator.update(table)

        let clickPointInTable = NSPoint(x: 100, y: 380)
        #expect(table.row(at: clickPointInTable) < 0)

        let windowPoint = table.convert(clickPointInTable, to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))

        let menu = table.menu(for: event)
        #expect(menu == nil)
        #expect(session.selectedLayerIDs == initialSelection)
    }

    @Test func testContextMenuDuplicateUsesExistingDuplicateOperation() throws {
        let session = sessionWithThreeLayers()
        let (_, coordinator, _) = makeLayerTable(session: session)

        let target = try #require(session.activeLayer)
        let initialCount = session.document?.layers.count ?? 0
        let undoCount = session.history.undoCount

        coordinator.duplicateLayerAction(nil)

        let layers = try #require(session.document?.layers)
        #expect(layers.count == initialCount + 1)
        #expect(layers.contains { $0.id == target.id }, "original remains")
        let copy = try #require(session.activeLayer)
        #expect(copy.id != target.id, "duplicated layer is new")
        #expect(copy.name == "\(target.name) copy")
        #expect(session.activeLayerID == copy.id, "active layer is the duplicate")
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Duplicate Layer")
    }

    @Test func testContextMenuDuplicateFolderPreservesHierarchy() throws {
        let session = sessionWithThreeLayers()
        session.groupSelectedLayers()
        let folderID = try #require(session.activeLayerID)
        let (_, coordinator, _) = makeLayerTable(session: session)

        let originalChildren = session.descendantIDs(of: folderID)
        #expect(!originalChildren.isEmpty)

        coordinator.duplicateLayerAction(nil)

        let newFolder = try #require(session.activeLayer)
        #expect(newFolder.id != folderID)
        #expect(newFolder.isGroup)
        let duplicatedChildren = session.descendantIDs(of: newFolder.id)
        #expect(duplicatedChildren.count == originalChildren.count)
        for childID in duplicatedChildren {
            let child = session.document?.layers.first { $0.id == childID }
            #expect(child?.parentID == newFolder.id)
        }
    }

    @Test func testContextMenuMaskActionsFollowLayerState() throws {
        let session = sessionWithThreeLayers()
        let (table, coordinator, _) = makeLayerTable(session: session)

        // Without mask:
        var menu = try #require(coordinator.contextMenu(for: 0))
        let addMaskItem = try #require(menu.items.first { $0.title == "Add Mask" })
        #expect(addMaskItem.isEnabled == true)
        let deleteMaskItem = try #require(menu.items.first { $0.title == "Delete Layer Mask" })
        #expect(deleteMaskItem.isEnabled == false)
        let applyMaskItem = try #require(menu.items.first { $0.title == "Apply Layer Mask" })
        #expect(applyMaskItem.isEnabled == false)
        let toggleMaskItem = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.toggleMaskAction) })
        #expect(toggleMaskItem.isEnabled == false)

        // Add a reveal-all mask
        coordinator.revealAllMaskAction(nil)
        #expect(session.activeLayer?.mask != nil)
        #expect(session.activeLayer?.mask?.isEnabled == true)

        // With mask (enabled):
        coordinator.update(table)
        menu = try #require(coordinator.contextMenu(for: 0))
        let addMaskAfter = try #require(menu.items.first { $0.title == "Add Mask" })
        #expect(addMaskAfter.isEnabled == false)
        let toggleMaskAfter = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.toggleMaskAction) })
        #expect(toggleMaskAfter.isEnabled == true)
        #expect(toggleMaskAfter.title == "Disable Layer Mask")
        let deleteMaskAfter = try #require(menu.items.first { $0.title == "Delete Layer Mask" })
        #expect(deleteMaskAfter.isEnabled == true)
        let applyMaskAfter = try #require(menu.items.first { $0.title == "Apply Layer Mask" })
        #expect(applyMaskAfter.isEnabled == false, "a blank layer has no pixels of its own to bake the mask into")

        // Disable mask
        coordinator.toggleMaskAction(nil)
        #expect(session.activeLayer?.mask?.isEnabled == false)
        coordinator.update(table)
        menu = try #require(coordinator.contextMenu(for: 0))
        let toggleMaskDisabled = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.toggleMaskAction) })
        #expect(toggleMaskDisabled.title == "Enable Layer Mask")
        // A disabled mask can't be applied — Photoshop asks first; here it's simply left off.
        let applyMaskDisabled = try #require(menu.items.first { $0.title == "Apply Layer Mask" })
        #expect(applyMaskDisabled.isEnabled == false)

        // Delete mask
        coordinator.deleteMaskAction(nil)
        #expect(session.activeLayer?.mask == nil)
    }

    @Test func testContextMenuShowsCreateOrReleaseClippingAction() throws {
        let session = sessionWithThreeLayers()
        let (table, coordinator, _) = makeLayerTable(session: session)

        let layers = session.layerRows.map(\.layer)
        // Select top layer (row 0 in layerRows)
        session.selectLayer(layers[0].id)
        coordinator.update(table)

        var menu = try #require(coordinator.contextMenu(for: 0))
        var clippingItem = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.toggleClippingMaskAction) })
        #expect(clippingItem.title == "Create Clipping Mask")
        #expect(clippingItem.isEnabled == true)

        // Create clipping mask
        coordinator.toggleClippingMaskAction(nil)
        #expect(session.activeLayer?.maskSourceID != nil)

        // Now it is clipped -> shows Release Clipping Mask
        coordinator.update(table)
        menu = try #require(coordinator.contextMenu(for: 0))
        clippingItem = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.toggleClippingMaskAction) })
        #expect(clippingItem.title == "Release Clipping Mask")
        #expect(clippingItem.isEnabled == true)

        // Release clipping mask
        coordinator.toggleClippingMaskAction(nil)
        #expect(session.activeLayer?.maskSourceID == nil)
    }

    @Test func testContextMenuUsesExistingMergeTitleAndAction() throws {
        let session = sessionWithThreeLayers()
        let (table, coordinator, _) = makeLayerTable(session: session)

        // 1 layer selected (top): can merge down
        let layers = session.layerRows.map(\.layer)
        session.selectLayer(layers[0].id)
        coordinator.update(table)
        var menu = try #require(coordinator.contextMenu(for: 0))
        var mergeItem = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.mergeLayersAction) })
        #expect(mergeItem.title == session.mergeTitle)
        #expect(mergeItem.title == "Merge Down")
        #expect(mergeItem.isEnabled == session.canMergeLayers)

        // Multi-selection: "Merge Layers"
        session.selectLayers([layers[0].id, layers[1].id], primary: layers[0].id)
        coordinator.update(table)
        menu = try #require(coordinator.contextMenu(for: 0))
        mergeItem = try #require(menu.items.first { $0.action == #selector(NativeLayerList.Coordinator.mergeLayersAction) })
        #expect(mergeItem.title == session.mergeTitle)
        #expect(mergeItem.title == "Merge Layers")
        #expect(mergeItem.isEnabled == session.canMergeLayers)

        // Execute merge
        let beforeCount = session.document?.layers.count ?? 0
        coordinator.mergeLayersAction(nil)
        #expect((session.document?.layers.count ?? 0) == beforeCount - 1)
    }

    @Test func testContextMenuActionsPreserveUndoRedo() throws {
        let session = sessionWithThreeLayers()
        let (_, coordinator, _) = makeLayerTable(session: session)

        let initialLayers = session.document?.layers

        // 1. Duplicate & Undo
        coordinator.duplicateLayerAction(nil)
        #expect(session.document?.layers.count == 4)
        session.undo()
        #expect(session.document?.layers == initialLayers)
        session.redo()
        #expect(session.document?.layers.count == 4)
        session.undo()

        // 2. Add Mask & Undo
        coordinator.revealAllMaskAction(nil)
        #expect(session.activeLayer?.mask != nil)
        session.undo()
        #expect(session.activeLayer?.mask == nil)

        // 3. Visibility toggle & Undo
        let wasVisible = session.activeLayer?.isVisible == true
        coordinator.toggleVisibilityAction(nil)
        #expect(session.activeLayer?.isVisible == !wasVisible)
        session.undo()
        #expect(session.activeLayer?.isVisible == wasVisible)
    }

    private func coloredAsset(_ color: CGColor, name: String, size: Int = 4) throws -> ImportedImage {
        let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(ctx.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: name)
    }

    @Test func mergeVisibleCombinesOnlyVisibleLayersAtTheTopmostSlotAndUndoes() throws {
        let session = EditorSession()
        session.insert(try coloredAsset(CGColor(red: 1, green: 0, blue: 0, alpha: 1), name: "Red"))
        let red = try #require(session.activeLayerID)
        session.insert(try coloredAsset(CGColor(red: 0, green: 1, blue: 0, alpha: 1), name: "Green"))
        let green = try #require(session.activeLayerID)
        session.insert(try coloredAsset(CGColor(red: 0, green: 0, blue: 1, alpha: 1), name: "Blue"))
        let blue = try #require(session.activeLayerID)
        session.toggleLayerVisibility(green)
        #expect(session.canMergeVisible)

        let undoCount = session.history.undoCount
        session.mergeVisible()
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 2, "the hidden green layer stays out of the merge")
        #expect(layers.first { $0.id == green }?.isVisible == false)
        let merged = try #require(session.activeLayer)
        #expect(merged.id != red && merged.id != blue)
        #expect(merged.name == "Blue", "named after the topmost visible layer")
        #expect(merged.parentID == nil)
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Merge Visible")

        session.undo()
        #expect(session.document?.layers.map(\.id) == [red, green, blue])
        session.redo()
        #expect(session.document?.layers.count == 2)

        // Only the hidden layer is left: nothing visible remains to combine.
        session.selectLayer(merged.id)
        session.deleteActiveLayer()
        #expect(!session.canMergeVisible)
    }

    @Test func flattenImageDiscardsHiddenLayersAsOneUndo() throws {
        let session = EditorSession()
        session.insert(try coloredAsset(CGColor(red: 1, green: 0, blue: 0, alpha: 1), name: "Red"))
        let red = try #require(session.activeLayerID)
        session.insert(try coloredAsset(CGColor(red: 0, green: 1, blue: 0, alpha: 1), name: "Green"))
        let green = try #require(session.activeLayerID)
        session.toggleLayerVisibility(green)

        let undoCount = session.history.undoCount
        session.flattenImage()
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 1)
        #expect(layers[0].name == "Background")
        #expect(layers[0].id != red && layers[0].id != green)
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Flatten Image")

        session.undo()
        #expect(session.document?.layers.map(\.id) == [red, green])
    }

    @Test func layerStyleCopyPasteAndClearActOnEveryStyleableSelectedLayer() throws {
        let session = EditorSession()
        session.insert(try coloredAsset(CGColor(red: 1, green: 0, blue: 0, alpha: 1), name: "Red"))
        let styled = try #require(session.activeLayerID)
        session.insert(try coloredAsset(CGColor(red: 0, green: 1, blue: 0, alpha: 1), name: "Green"))
        let plain = try #require(session.activeLayerID)
        session.addGroup()
        let group = try #require(session.activeLayerID)

        #expect(!session.canCopyLayerStyle)
        session.selectLayer(styled)
        var effects = LayerEffects()
        effects.shadow = ShadowEffect()
        session.setEffects(effects, name: "Add Drop Shadow")
        #expect(session.canCopyLayerStyle)
        session.copyLayerStyle()
        #expect(session.copiedLayerEffects?.shadow != nil)

        session.selectLayers([plain, group], primary: plain)
        #expect(session.canPasteLayerStyle)
        let undoCount = session.history.undoCount
        session.pasteLayerStyle()
        #expect(session.document?.layers.first { $0.id == plain }?.effects?.shadow != nil)
        #expect(session.document?.layers.first { $0.id == group }?.effects == nil, "a group can't hold effects")
        #expect(session.history.undoCount == undoCount + 1, "one undo step, even with two targets")
        session.undo()
        #expect(session.document?.layers.first { $0.id == plain }?.effects == nil)

        session.selectLayers([styled, plain], primary: styled)
        session.pasteLayerStyle()
        #expect(session.canClearLayerStyle)
        session.clearLayerStyle()
        #expect(session.document?.layers.first { $0.id == styled }?.effects == nil)
        #expect(session.document?.layers.first { $0.id == plain }?.effects == nil)
        #expect(!session.canClearLayerStyle)
    }

    @Test func toggleOtherLayersVisibilitySoloAndRestoreAsOneUndoStep() throws {
        let session = sessionWithThreeLayers()
        let layers = try #require(session.document?.layers)
        let (first, second, third) = (layers[0].id, layers[1].id, layers[2].id)
        #expect(session.canToggleOtherLayers)
        #expect(session.hasOtherVisibleLayers(than: first))

        let undoCount = session.history.undoCount
        session.toggleOtherLayersVisibility(first)
        #expect(session.document?.layers.first { $0.id == first }?.isVisible == true)
        #expect(session.document?.layers.first { $0.id == second }?.isVisible == false)
        #expect(session.document?.layers.first { $0.id == third }?.isVisible == false)
        #expect(session.history.undoCount == undoCount + 1)
        #expect(session.history.undoName == "Hide Other Layers")
        #expect(!session.hasOtherVisibleLayers(than: first))

        // Everything else is already hidden, so the same command brings it all back.
        session.toggleOtherLayersVisibility(first)
        #expect(session.document?.layers.allSatisfy { $0.isVisible } == true)
        #expect(session.history.undoName == "Show Other Layers")

        session.undo()
        #expect(session.document?.layers.first { $0.id == second }?.isVisible == false)
        session.undo()
        #expect(session.document?.layers.allSatisfy { $0.isVisible } == true)
    }
}
