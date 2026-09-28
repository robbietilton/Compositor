import AppKit
import SwiftUI
import Testing
@testable import Compositor

/// Photoshop's Layers-panel menu depends on where you right-click. `contextMenu`/`pixelThumbnailMenu`/
/// `maskThumbnailMenu`/`eyeMenu` cover each hit zone's contents directly; the `rightClickOn…` tests drive a real
/// click through `LayerTableView.menu(for:)` to prove the routing itself finds the right subview.
@MainActor
struct LayerContextMenuTests {
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

    private func coloredAsset(_ name: String) throws -> ImportedImage {
        let ctx = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(ctx.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: name)
    }

    // MARK: Menu contents per zone

    @Test func pixelThumbnailMenuOffersSelectThenCombineModesGatedBySelection() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.insert(try coloredAsset("Red"))
        let (_, coordinator, _) = makeLayerTable(session: session)

        var menu = try #require(coordinator.pixelThumbnailMenu(for: 0))
        #expect(menu.items.count == 5, "Select Pixels, a separator, then three combine modes")
        #expect(menu.items[1].isSeparatorItem)
        let actionable = menu.items.filter { !$0.isSeparatorItem }
        #expect(actionable.map(\.title) == ["Select Pixels", "Add Pixels to Selection",
                                            "Subtract Pixels from Selection", "Intersect Pixels with Selection"])
        #expect(actionable[0].isEnabled)
        #expect(actionable[1...].allSatisfy { !$0.isEnabled }, "nothing to combine without a selection")

        coordinator.selectPixelsAction(nil)
        #expect(session.selection != nil)
        menu = try #require(coordinator.pixelThumbnailMenu(for: 0))
        let afterSelecting = menu.items.filter { !$0.isSeparatorItem }
        #expect(afterSelecting[1...].allSatisfy { $0.isEnabled })
    }

    @Test func maskThumbnailMenuOffersMaskLifecycleThenCombineModesThenLink() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.insert(try coloredAsset("Red"))
        session.addLayerMask(revealing: false) // all black, so Select Mask has something to trace
        let (_, coordinator, _) = makeLayerTable(session: session)

        let menu = try #require(coordinator.maskThumbnailMenu(for: 0))
        let actionable = menu.items.filter { !$0.isSeparatorItem }
        #expect(actionable.map(\.title) == ["Disable Layer Mask", "Delete Layer Mask", "Apply Layer Mask", "Select Mask",
                                            "Add Mask to Selection", "Subtract Mask from Selection",
                                            "Intersect Mask with Selection", "Unlink Mask"])
        #expect(actionable[0].isEnabled && actionable[1].isEnabled && actionable[2].isEnabled)
        #expect(actionable[4...6].allSatisfy { !$0.isEnabled }, "no selection yet to combine with")
        #expect(actionable[7].isEnabled, "a fresh mask starts linked")

        coordinator.selectMaskAction(nil)
        #expect(session.selection != nil)
        let after = try #require(coordinator.maskThumbnailMenu(for: 0)).items.filter { !$0.isSeparatorItem }
        #expect(after[4...6].allSatisfy { $0.isEnabled })
    }

    @Test func eyeMenuOffersThisLayerThenAllOthersAndBothTitlesTrackState() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        for _ in 0..<3 { session.addBlankLayer() }
        let top = try #require(session.activeLayerID)
        let (_, coordinator, _) = makeLayerTable(session: session)

        var menu = try #require(coordinator.eyeMenu(for: 0))
        #expect(menu.items.map(\.title) == ["Hide This Layer", "Hide All Other Layers"], "the other two are still visible")

        coordinator.toggleOtherLayersVisibilityAction(nil)
        #expect(session.document?.layers.filter { $0.isVisible }.map(\.id) == [top])
        menu = try #require(coordinator.eyeMenu(for: 0))
        #expect(menu.items.map(\.title) == ["Hide This Layer", "Show All Other Layers"],
                "the target is still visible; only the others' title flips")

        coordinator.toggleVisibilityAction(nil)
        menu = try #require(coordinator.eyeMenu(for: 0))
        #expect(menu.items.map(\.title) == ["Show This Layer", "Show All Other Layers"],
                "now hidden itself too, and everyone else already is")
    }

    // MARK: Right-click routes to the zone actually clicked, selecting its row first

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }

    /// Two rows — "Bottom" and, on top, "Top" (masked) — hosted in a real window with Auto Layout resolved, so
    /// a row's thumbnails and eye have real frames for `LayerTableView`'s own hit-testing to find.
    private func hostedTwoLayers(maskOnTop: Bool) throws -> (session: EditorSession, bottom: UUID, top: UUID, table: LayerTableView, window: NSWindow) {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        session.insert(try coloredAsset("Bottom"))
        let bottom = try #require(session.activeLayerID)
        session.insert(try coloredAsset("Top"))
        let top = try #require(session.activeLayerID)
        if maskOnTop { session.addLayerMask() }
        session.selectLayers([bottom], primary: bottom) // a different row than the one about to be clicked
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 252, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let table = try #require(descendants(host).compactMap { $0 as? LayerTableView }.first)
        return (session, bottom, top, table, window)
    }

    private func rightClick(at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func rightClickOnAPixelThumbnailSelectsItsRowAndShowsThePixelMenu() throws {
        let (session, _, top, table, window) = try hostedTwoLayers(maskOnTop: false)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        cell.layoutSubtreeIfNeeded()
        let thumbnail = try #require(descendants(cell).first {
            $0 is NSButton && $0.accessibilityLabel()?.hasPrefix("Select image") == true
        })
        let point = thumbnail.convert(NSPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY), to: nil)

        let menu = try #require(table.menu(for: rightClick(at: point, in: window)))
        #expect(session.selectedLayerIDs == [top], "row 0 — the topmost layer — is the one actually clicked")
        #expect(session.activeLayerID == top)
        #expect(!session.isMaskSelected)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Select Pixels"))
        #expect(!titles.contains("Duplicate Layer"), "the pixel-thumbnail menu, not the row menu")
    }

    @Test func rightClickOnAMaskThumbnailSelectsItsRowAndShowsTheMaskMenu() throws {
        let (session, _, top, table, window) = try hostedTwoLayers(maskOnTop: true)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        cell.layoutSubtreeIfNeeded()
        let thumbnail = try #require(descendants(cell).first {
            $0 is NSButton && $0.accessibilityLabel()?.hasPrefix("Select mask") == true
        })
        let point = thumbnail.convert(NSPoint(x: thumbnail.bounds.midX, y: thumbnail.bounds.midY), to: nil)

        let menu = try #require(table.menu(for: rightClick(at: point, in: window)))
        #expect(session.selectedLayerIDs == [top])
        #expect(session.activeLayerID == top)
        #expect(session.isMaskSelected, "the mask thumbnail targets the mask, not the layer")
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Select Mask"))
        #expect(!titles.contains("Duplicate Layer"))
    }

    @Test func rightClickOnTheEyeSelectsItsRowAndShowsTheEyeMenu() throws {
        let (session, _, top, table, window) = try hostedTwoLayers(maskOnTop: false)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: false))
        cell.layoutSubtreeIfNeeded()
        let eye = try #require(descendants(cell).first {
            $0 is NSButton && ($0.accessibilityLabel()?.hasPrefix("Hide ") == true || $0.accessibilityLabel()?.hasPrefix("Show ") == true)
        })
        let point = eye.convert(NSPoint(x: eye.bounds.midX, y: eye.bounds.midY), to: nil)

        let menu = try #require(table.menu(for: rightClick(at: point, in: window)))
        #expect(session.selectedLayerIDs == [top])
        #expect(session.activeLayerID == top)
        #expect(!session.isMaskSelected)
        #expect(menu.items.map(\.title) == ["Hide This Layer", "Hide All Other Layers"])
    }
}
