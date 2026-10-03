import AppKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor struct ProjectWorkspaceTests {
    @Test func newCanvasOpensAnEmptyTabWithoutAModal() {
        let workspace = ProjectWorkspace()
        let original = workspace.current
        original.session.createDocument(width: 4000, height: 3000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current !== original)
        #expect(workspace.current.session.document == nil)
        #expect(!workspace.current.session.showsNewDocument)
        #expect(workspace.canSwitch)
        #expect(original.session.document?.size.width == 4000)
        workspace.newCanvas()
        #expect(workspace.tabs.count == 3)
        #expect(!workspace.current.session.showsNewDocument)
    }

    /// A gradient waiting for Apply used to leave Quit and the close button doing nothing at all; quitting applies it.
    @Test func quittingAppliesAPendingGradient() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.addBlankLayer()
        session.selectTool(.gradient)
        session.beginGradient(at: CGPoint(x: 0, y: 10))
        session.moveGradient(end: CGPoint(x: 100, y: 10))
        session.endGradientDrag()
        #expect(!workspace.canSwitch)
        let count = session.history.undoCount
        await session.settlePendingEdits()
        #expect(session.gradientEdit == nil)
        #expect(session.history.undoCount == count + 1)
        #expect(workspace.canSwitch)
    }

    /// An open dialog used to block Quit too; quitting cancels it, leaving the layer as it was.
    @Test func quittingCancelsAnOpenDialog() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.insert(try LiveMaskTests().asset([200, 100, 50, 255]))
        let original = session.activeLayer?.asset?.image
        for open in [{ session.beginFilter(.gaussianBlur) }, { session.beginHueSaturation() }, { session.beginLevels() }] {
            open()
            #expect(!workspace.canSwitch)
            await session.settlePendingEdits()
            #expect(workspace.canSwitch)
            #expect(session.activeLayer?.asset?.image === original)
        }
    }

    /// An effect's panel left open used to have its changes saved on Quit though they were never OK'd; quitting
    /// cancels it as its Cancel button would, so a new Stroke comes off again and a Drop Shadow keeps its distance, even
    /// with Color Range open beside the panel, which keeps layers from being edited until it's closed.
    @Test func quittingCancelsAnOpenEffectsPanel() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.insert(try LiveMaskTests().asset([200, 100, 50, 255]))
        let id = try #require(session.activeLayerID)
        func saved() -> LayerEffects? { session.projectSnapshot()?.manifest.layers.first { $0.id == id }?.effects }
        session.addEffect(.stroke)
        session.beginColorRange()
        #expect(saved()?.stroke != nil)
        #expect(session.colorRange != nil)
        await session.settlePendingEdits()
        #expect(session.effectsEditing == nil)
        #expect(saved() == nil)

        session.addEffect(.shadow)
        session.finishEffectsEditing(commit: true)
        session.selectEffect(.shadow, on: id, editing: true)
        session.changeEffects { $0.shadow?.distance = 60 }
        await session.settlePendingEdits()
        #expect(session.effectsEditing == nil)
        #expect(saved()?.shadow?.distance == 20)
    }

    /// While the project is busy the panel's Cancel can't go in, so settling leaves the panel open and the layer as it
    /// is, rather than closing the panel over an effect that was never OK'd; once it can, settling cancels it.
    @Test func settlingWhileBusyLeavesTheEffectsPanelOpen() async throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 100, height: 20)
        session.insert(try LiveMaskTests().asset([200, 100, 50, 255]))
        let id = try #require(session.activeLayerID)
        session.addEffect(.stroke)
        session.isProjectBusy = true
        await session.settlePendingEdits()
        #expect(session.effectsEditing != nil)
        #expect(session.document?.layers.first { $0.id == id }?.effects?.stroke != nil)
        session.isProjectBusy = false
        await session.settlePendingEdits()
        #expect(session.effectsEditing == nil)
        #expect(session.document?.layers.first { $0.id == id }?.effects == nil)
    }

    @Test func layerDropProviderCopiesIntoANewProject() async throws {
        let workspace = ProjectWorkspace()
        let source = workspace.current
        source.session.createDocument(width: 100, height: 100)
        source.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let id = try #require(source.session.activeLayerID)
        let provider = NSItemProvider(item: Data(id.uuidString.utf8) as NSData, typeIdentifier: ProjectWorkspace.layerType)
        await workspace.receiveProviders([provider])
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id != source.id)
        #expect(workspace.current.session.document?.layers.count == 1)
        #expect(workspace.current.session.activeLayerID != id)
        #expect(source.session.document?.layers.first?.id == id)
    }

    @Test func tabsKeepIndependentDocumentsAndUndo() throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 4000, height: 4000)
        first.session.addBlankLayer()
        let second = workspace.addTab()
        second.session.createDocument(width: 640, height: 480)
        second.session.addBlankLayer()
        second.session.undo()
        #expect(first.session.document?.layers.count == 1)
        #expect(second.session.document?.layers.isEmpty == true)
        workspace.select(first.id)
        #expect(workspace.current === first)
        #expect(first.session.document?.size.width == 4000)
        workspace.removeTab(second.id)
        #expect(workspace.current === first)
        workspace.removeTab(first.id)
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
    }

    @Test func crossProjectCopyRemapsIdentityAndHasIndependentUndo() async throws {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        first.session.createDocument(width: 100, height: 100)
        first.session.insert(try LiveMaskTests().asset([255,255,255,255]))
        let original = try #require(first.session.activeLayerID)
        let second = workspace.addTab()
        second.session.createDocument(width: 200, height: 200)
        await workspace.copyLayer(original, into: second.id)
        let copied = try #require(second.session.document?.layers.first)
        #expect(copied.id != original)
        #expect(copied.transform.center == CGPoint(x: 100, y: 100))
        #expect(first.session.document?.layers.count == 1)
        second.session.undo()
        #expect(second.session.document?.layers.isEmpty == true)
        #expect(first.session.document?.layers.count == 1)
        second.session.redo()
        #expect(second.session.document?.layers.first?.id == copied.id)
    }

    @Test func dockCreatesTabsAndTargetedImportUsesExistingTab() async throws {
        let url = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        await workspace.receive([url, url])
        #expect(workspace.tabs.count == 2)
        let first = workspace.tabs[0]
        await workspace.receive([url], into: first.id)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current === first)
        #expect(first.session.document?.layers.count == 2)
        #expect(workspace.tabs[1].session.document?.layers.count == 1)
    }

    /// A project of three layers, one masked, saved as a package.
    private func savedProject() throws -> URL {
        let saved = EditorSession()
        saved.createDocument(width: 400, height: 300)
        for seed in 0..<3 {
            let context = try BrushRaster.context(width: 400 - seed * 80, height: 300 - seed * 60, mask: false)
            context.setFillColor(red: CGFloat(seed) / 3, green: 0.5, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height / 2))
            let image = context.makeImage()!
            saved.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        }
        let mask = try BrushRaster.context(width: 240, height: 180, mask: true)
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
        saved.document!.layers[saved.document!.layers.count - 1].mask = LayerMask(asset: try LayerMask.asset(from: mask.makeImage()!))
        let url = FileManager.default.temporaryDirectory.appending(path: "first-frame-\(UUID().uuidString).comp")
        try ProjectStore.package(for: try #require(saved.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// A project opened in a tab draws its first frame from textures made before the tab showed: the frame uploads
    /// nothing.
    @Test func anOpenedProjectsFirstFrameUploadsNothing() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(url))
        // From here on nothing is awaited, so no other test's frame comes between.
        let session = workspace.current.session
        let document = try #require(session.document)
        #expect(document.canvasSources.count == 4)
        let canvas = CanvasView(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        session.viewport.resize(to: canvas.bounds.size, backingScale: 2, documentSize: document.size)
        let before = renderer.uploads
        #expect(canvas.gpuFrame(size: CGSize(width: 1000, height: 800)) != nil)
        #expect(renderer.uploads == before)
    }

    /// A project opened together with an image goes behind the image's tab at once, so nothing is made for it ahead:
    /// it makes its textures as it's brought forward.
    @Test func aProjectOpenedWithAnImageMakesNoTexturesAhead() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let url = try savedProject(), image = try ImageImportTests().fixture(.png)
        defer { for file in [url, image] { try? FileManager.default.removeItem(at: file) } }
        let workspace = ProjectWorkspace()
        await workspace.receive([url, image])
        let project = try #require(workspace.tabs.first { $0.session.projectURL != nil })
        #expect(workspace.current !== project)
        let images = try #require(project.session.document).layers.compactMap { $0.asset?.image }
        #expect(images.count == 3 && images.allSatisfy { renderer.cachedLevels(of: $0).isEmpty })
    }

    /// A project opened together with one already open in a tab goes behind that tab at once, so nothing is made for it
    /// ahead either.
    @Test func aProjectOpenedBeforeOneAlreadyOpenMakesNoTexturesAhead() async throws {
        let renderer = try #require(GPUCanvasRenderer.shared)
        let first = try savedProject(), open = try savedProject()
        defer { for file in [first, open] { try? FileManager.default.removeItem(at: file) } }
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(open))
        await workspace.receive([first, open])
        let project = try #require(workspace.tabs.first { $0.session.projectURL?.lastPathComponent == first.lastPathComponent })
        #expect(workspace.current !== project)
        let images = try #require(project.session.document).layers.compactMap { $0.asset?.image }
        #expect(images.count == 3 && images.allSatisfy { renderer.cachedLevels(of: $0).isEmpty })
    }

    /// Saving an opened project encodes nothing it read, and after one layer's pixels change, only that layer.
    @Test func savingAnOpenedProjectEncodesOnlyWhatChanged() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(url))
        let tab = workspace.current
        #expect(await tab.controller.save())
        #expect(tab.controller.encoded.encoded == 0)
        let image = try #require(tab.session.document?.layers.first(where: { $0.asset != nil })?.asset?.image)
        let context = try BrushRaster.copy(image)
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let painted = try #require(context.makeImage())
        let index = try #require(tab.session.document?.layers.firstIndex { $0.asset != nil })
        tab.session.document!.layers[index].asset = ImportedImage(image: painted, thumbnail: painted, name: "Layer")
        #expect(await tab.controller.save())
        #expect(tab.controller.encoded.encoded == 1)
    }

    @Test func moveTabReordersWithoutTouchingSelectionOrDocuments() {
        let workspace = ProjectWorkspace()
        let a = workspace.current
        let b = workspace.addTab(reuseEmpty: false)
        let c = workspace.addTab(reuseEmpty: false)
        #expect(workspace.tabs.map(\.id) == [a.id, b.id, c.id])
        workspace.moveTab(c.id, to: 0)
        #expect(workspace.tabs.map(\.id) == [c.id, a.id, b.id])
        workspace.moveTab(a.id, to: 2)
        #expect(workspace.tabs.map(\.id) == [c.id, b.id, a.id])
        // An out-of-range target clamps to the array's bounds instead of crashing.
        workspace.moveTab(c.id, to: 99)
        #expect(workspace.tabs.map(\.id) == [b.id, a.id, c.id])
        // Moving to where a tab already is, or moving an id that isn't a tab, does nothing.
        let unchanged = workspace.tabs.map(\.id)
        workspace.moveTab(c.id, to: 2)
        workspace.moveTab(UUID(), to: 0)
        #expect(workspace.tabs.map(\.id) == unchanged)
        #expect(workspace.current === c) // reordering is chrome — it never moves the selection
    }

    /// Quit asks about the project on screen first, then the others left to right.
    @Test @MainActor func quitAsksAboutTheActiveTabFirst() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let second = workspace.addTab(reuseEmpty: false)
        let third = workspace.addTab(reuseEmpty: false)
        workspace.select(second.id)
        #expect(workspace.quitOrder.map(\.id) == [second.id, first.id, third.id])
        workspace.select(third.id)
        #expect(workspace.quitOrder.map(\.id) == [third.id, first.id, second.id])
        workspace.select(first.id)
        #expect(workspace.quitOrder.map(\.id) == [first.id, second.id, third.id])
    }
}
