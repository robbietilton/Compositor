import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Compositor

/// What's still in progress when an iPad tab closes, saves or leaves the screen: kept as the Mac's Quit keeps it, and
/// never written half done.
@MainActor struct PadUnfinishedEditTests {
    /// A tab whose project, a 200 × 100 canvas with a gray layer over an empty one, has a file of its own and nothing
    /// left to save.
    private func tab() async throws -> EditorTab {
        let tab = EditorTab()
        let session = tab.session
        session.viewport.resize(to: CGSize(width: 200, height: 100), backingScale: 1, documentSize: nil)
        session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        return tab
    }

    /// The project its file holds, flattened, and a reader for one pixel's red and alpha, from the top left.
    private func savedPixels(_ url: URL) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try ProjectStore.readPackage(url)).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    /// One pixel's red and alpha in `image`, from the top left.
    private func pixel(of image: CGImage, _ x: Int, _ y: Int) throws -> (red: Int, alpha: Int) {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[3]))
    }

    /// Waits up to a few seconds for `condition`, as the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Closing a tab

    /// Text being typed goes into the project as Done would put it, as the Mac's Quit does.
    @Test func textBeingTypedIsKeptWhenTheTabCloses() async throws {
        let tab = try await tab()
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        tab.session.selectTool(.type)
        tab.session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        tab.session.textDraft?.style.content = "Hello"
        await tab.close()

        #expect(try ProjectStore.readPackage(url).manifest.layers.compactMap(\.text?.content) == ["Hello"])
    }

    /// A gradient waiting for Apply is applied.
    @Test func aGradientWaitingForApplyIsAppliedWhenTheTabCloses() async throws {
        let tab = try await tab()
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        session.addBlankLayer()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 50))
        session.moveGradient(end: CGPoint(x: 200, y: 50))
        session.endGradientDrag()
        #expect(session.gradientEdit != nil)
        await tab.close()

        // Black from the foreground color at the left, where the gray layer shows today.
        #expect(try await savedPixels(url)(4, 50).red < 40)
    }

    /// Selected pixels being moved are put down where they are.
    @Test func pixelsBeingMovedArePutDownWhenTheTabCloses() async throws {
        let tab = try await tab()
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        session.selectAll()
        #expect(session.beginPixelMove())
        session.movePixels(by: CGSize(width: 100, height: 0))
        await tab.close()

        let pixels = try await savedPixels(url)
        #expect(pixels(10, 50).alpha == 0)
        #expect(pixels(150, 50).alpha == 255)
    }

    /// A stroke still being drawn is kept, as lifting the finger would keep it.
    @Test func aStrokeBeingDrawnIsKeptWhenTheTabCloses() async throws {
        let tab = try await tab()
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        session.addBlankLayer()
        session.selectTool(.brush)
        session.beginBrush(at: CGPoint(x: 20, y: 50))
        session.continueBrush(at: CGPoint(x: 180, y: 50))
        #expect(session.brushStroke != nil)
        await tab.close()

        #expect(try await savedPixels(url)(100, 50).red < 60)
    }

    /// An adjustment layer's editor is cancelled, as its Cancel button would: what it was previewing isn't saved.
    @Test func anAdjustmentBeingEditedIsCancelledWhenTheTabCloses() async throws {
        let tab = try await tab()
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        session.addAdjustment(.hsv)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        var settings = try #require(session.hueSaturation?.settings)
        settings.hue = 90
        session.updateHueSaturation(settings, preview: true)
        await tab.close()

        let saved = try ProjectStore.readPackage(url).manifest.layers.first { $0.id == id }
        #expect(saved?.adjustment?.resolvedHSV.hue == 0)
    }

    /// An adjustment's editor over the canvas goes with the tab it edits, rather than staying on over the next one.
    @Test func anAdjustmentEditorGoesWithItsTab() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let controller = EditorWindowController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 200, height: 100)
        tab.session.addAdjustment(.hsv)
        try await eventually { controller.presentedViewController is AdjustmentEditorController }
        #expect(controller.presentedViewController is AdjustmentEditorController)

        controller.close(tab.id)
        try await eventually { controller.presentedViewController == nil }
        #expect(controller.presentedViewController == nil)
        #expect(tab.session.hueSaturation == nil && tab.session.adjustmentEditingID == nil)
    }

    // MARK: Saving

    /// Save waits for text being typed, as on the Mac, where it's off until Done, and so does Duplicate, which saves
    /// first; and like the Mac's, Save sets a crop in progress aside and keeps a transform.
    @Test func saveIsTheMacsSave() async throws {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        tab.session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray"))
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        let save = #selector(EditorWindowController.saveProject(_:)), duplicate = #selector(EditorWindowController.duplicateProject(_:))
        #expect(controller.canPerformAction(save, withSender: nil) && controller.canPerformAction(duplicate, withSender: nil))

        tab.session.selectTool(.type)
        tab.session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        #expect(!controller.canPerformAction(save, withSender: nil))
        #expect(!controller.canPerformAction(duplicate, withSender: nil))
        tab.session.cancelText()

        tab.session.selectTool(.crop)
        tab.session.cropRect = CGRect(x: 10, y: 10, width: 50, height: 50)
        controller.saveProject(nil)
        #expect(tab.session.cropRect == nil)
        await controller.saving?.value

        let gray = try #require(tab.session.activeLayerID)
        tab.session.beginTransform()
        var moved = try #require(tab.session.transformEdit?.draft)
        moved.origin.x += 20
        tab.session.previewTransform(moved)
        controller.saveProject(nil)
        #expect(tab.session.transformEdit == nil)
        await controller.saving?.value
        #expect(try ProjectStore.readPackage(url).manifest.layers.first { $0.id == gray }?.transform == moved)
        await tab.close()
    }

    /// The save made as the app leaves the screen waits a moment for an edit already OK'd that's still being worked
    /// out, as a gradient's pixels are after Apply, so it goes in with the rest.
    @Test func leavingTheScreenWaitsForAnEditAlreadyOKd() async throws {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let tab = try #require(controller.activeTab)
        let session = tab.session
        session.createNewProject(width: 200, height: 100)
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }

        // An edit worked out for a moment, as Apply's are, which goes in as the project stops being busy.
        session.isProjectBusy = true
        let applying = Task {
            try? await Task.sleep(for: .milliseconds(300))
            session.isProjectBusy = false
            session.addBlankLayer()
        }
        controller.saveAll()
        await controller.saving?.value
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 2)
        await applying.value
        await tab.close()
    }

    // MARK: What a save writes

    /// A save while a selection is transformed writes the project as it was before, with no Floating Selection layer
    /// and no hole where the pixels were lifted; so Escape, which puts it back as it was, leaves the file right too.
    @Test func aSaveWhileASelectionIsTransformedWritesItAsItWas() async throws {
        let tab = try await tab()
        let document = try #require(tab.document)
        let url = document.fileURL
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        let gray = try #require(session.activeLayerID)
        session.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)),
                             name: "Rectangular Marquee")
        await session.beginSelectionTransform()
        #expect(session.transformEdit?.floating != nil)
        #expect(await document.save(to: url, for: .forOverwriting))
        for _ in 0..<20 { await Task.yield() }
        session.cancelTransform()
        await tab.close()

        let saved = try ProjectStore.readPackage(url)
        #expect(saved.manifest.layers.map(\.name) == ["Layer 1", "Gray"])
        let pixels = try #require(saved.images[gray]?.image)
        #expect(pixels.width == 200 && pixels.height == 100)
        #expect(try pixel(of: pixels, 50, 50).alpha == 255)
    }

    /// A save while an adjustment layer is edited writes the settings it had, not the ones being tried; so Cancel
    /// leaves the file right too.
    @Test func aSaveWhileAnAdjustmentIsEditedWritesItAsItWas() async throws {
        let tab = try await tab()
        let document = try #require(tab.document)
        let url = document.fileURL
        defer { try? FileManager.default.removeItem(at: url) }
        let session = tab.session
        session.addAdjustment(.hsv)
        let id = try #require(session.adjustmentEditingID)
        await session.beginAdjustmentEditing(id)
        var settings = try #require(session.hueSaturation?.settings)
        settings.hue = 90
        session.updateHueSaturation(settings, preview: true)
        #expect(await document.save(to: url, for: .forOverwriting))
        for _ in 0..<20 { await Task.yield() }
        session.cancelHueSaturation()
        await tab.close()

        let saved = try ProjectStore.readPackage(url).manifest.layers.first { $0.id == id }
        #expect(saved?.adjustment?.resolvedHSV.hue == 0)
    }

    // MARK: Leaving the screen

    /// Going to the background doesn't end typing, as it doesn't in Apple's own apps: the text being typed is saved as
    /// Done would put it, and isn't saved again while it stays open; Cancel afterwards makes the project to save again,
    /// which takes the text out of the file.
    @Test func textBeingTypedIsSavedWhenTheAppLeavesTheScreen() async throws {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 200, height: 100)
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        let document = try #require(tab.document)
        let url = document.fileURL
        defer { try? FileManager.default.removeItem(at: url) }
        func savedText() -> [String]? { try? ProjectStore.readPackage(url).manifest.layers.compactMap(\.text?.content) }
        tab.session.selectTool(.type)
        tab.session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        tab.session.textDraft?.style.content = "Hello"

        controller.saveAll()
        await controller.saving?.value
        #expect(savedText() == ["Hello"])
        #expect(tab.session.textDraft?.style.content == "Hello")
        // Not saved again and again while the text stays open.
        for _ in 0..<20 { await Task.yield() }
        #expect(!document.hasUnsavedChanges)

        tab.session.cancelText()
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)
        await tab.close()
        #expect(savedText() == [])
    }

    /// A dialog left open, which holds the project, doesn't hold up the save made as the app leaves the screen.
    @Test func aDialogLeftOpenDoesntHoldUpTheSave() async throws {
        let controller = EditorWindowController()
        controller.loadViewIfNeeded()
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 200, height: 100)
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        tab.session.addBlankLayer()
        let dialog = try #require(controller.canvasSizeDialog())
        #expect(tab.session.isProjectBusy)

        controller.saveAll()
        try await eventually { (try? ProjectStore.readPackage(url).manifest.layers.count) == 2 }
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 2)
        dialog.cancel()
        await tab.close()
    }

    /// The window going with a dialog open ends the dialog as Cancel would, and every project is saved and closed.
    @Test func theWindowGoingWithADialogOpenClosesEveryProject() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let controller = EditorWindowController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let tab = try #require(controller.activeTab)
        tab.session.createNewProject(width: 200, height: 100)
        try await tab.createDocument(named: "PadUnfinishedEditTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        tab.session.addBlankLayer()
        controller.canvasSize(nil)
        try await eventually { controller.presentedViewController is CanvasSizeController }
        try #require(controller.presentedViewController is CanvasSizeController)

        controller.closeAll()
        try await eventually { tab.document == nil }
        #expect(tab.document == nil)
        #expect(!tab.session.isProjectBusy)
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 2)
        (controller.presentedViewController as? SizeDialogController)?.cancel()
    }
}

