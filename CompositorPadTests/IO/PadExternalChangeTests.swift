import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Compositor

/// A project something else writes while it's open on iPad, as another app does through Files, or iCloud bringing down
/// a version written on the Mac: the editor takes it up as the Mac's does, but never in the middle of an edit, and
/// never over unsaved work without asking.
@Suite(.timeLimit(.minutes(1)))
@MainActor struct PadExternalChangeTests {
    /// A project of `layers` gray layers.
    private func project(layers: Int) throws -> ProjectSnapshot {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100)
        let context = try BrushRaster.context(width: 200, height: 100, mask: false)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())
        for _ in 0..<layers { session.insert(ImportedImage(image: image, thumbnail: image, name: "Gray")) }
        return try #require(session.projectSnapshot())
    }

    /// A project of two layers, saved in a folder of its own.
    private func savedProject() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PadExternalChangeTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appending(path: "Project.comp")
        try ProjectStore.package(for: try project(layers: 2)).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// Writes a project of `layers` layers over the package at `url`, as another app would: through a file
    /// coordinator, which tells the document that has it open. Off the main thread, where the document is told.
    private func writeElsewhere(_ url: URL, layers: Int) async throws {
        let package = try ProjectStore.package(for: try project(layers: layers))
        nonisolated(unsafe) let wrapper = package
        try await Task.detached {
            var coordinationError: NSError?, writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try? FileManager.default.removeItem(at: url)
                    try wrapper.write(to: url, options: [], originalContentsURL: nil)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
    }

    /// Waits up to a few seconds for `condition`, as the document's and the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A window on the app's screen showing `controller`, which alerts can be presented over.
    private func window(showing controller: EditorWindowController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    /// The project at `url`, opened in the window's tab in front. Through the tab, so the app's recent projects don't
    /// keep it.
    private func opened(_ url: URL, in controller: EditorWindowController) async throws -> EditorTab {
        let tab = try #require(controller.activeTab)
        _ = try await tab.open(url).value
        try #require(tab.document != nil)
        return tab
    }

    /// The first layer renamed, and not saved.
    private func renameFirstLayer(in tab: EditorTab) throws {
        let first = try #require(tab.session.document?.layers.first?.id)
        tab.session.renameLayer(first, to: "Unsaved here")
        #expect(tab.session.isModified)
    }

    private var changedOnDiskTitle: String { "“Project.comp” was changed on disk." }

    // MARK: Taking a change up

    /// With nothing unsaved, a change made elsewhere is taken up in place, as on the Mac.
    @Test func aChangeElsewhereIsTakenUp() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        #expect(tab.session.document?.layers.count == 2)

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.document?.layers.count == 3 }
        #expect(tab.session.document?.layers.count == 3)
        #expect(!tab.session.isModified)
        await tab.close()
    }

    /// A change made elsewhere after the project has saved is taken up too. UIDocument stops reverting on its own once
    /// the document has saved, so this is the document's own check.
    @Test func aChangeAfterASaveIsTakenUp() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let document = try #require(tab.document)
        tab.session.addBlankLayer()
        try await eventually { document.hasUnsavedChanges }
        #expect(await document.autosave())

        try await writeElsewhere(url, layers: 5)
        try await eventually { tab.session.document?.layers.count == 5 }
        #expect(tab.session.document?.layers.count == 5)
        #expect(!tab.session.isModified)
        await tab.close()
    }

    /// A package that was only touched, as a sync client adding a file of its own does, isn't a change, as on the Mac:
    /// nothing is asked. A real change after it still is.
    @Test func aTouchIsNotAChange() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        try renameFirstLayer(in: tab)

        try await Task.detached {
            var coordinationError: NSError?, writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
                do { try Data("synced".utf8).write(to: url.appending(path: "Sync Notes.txt")) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
        try await Task.sleep(for: .seconds(1))
        #expect(!tab.session.changedOnDisk)
        #expect(tab.session.document?.layers.first?.name == "Unsaved here")

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.changedOnDisk }
        #expect(tab.session.changedOnDisk)
        tab.document?.answerChangeOnDisk(revert: false)
        await tab.close()
    }

    /// The project's own save isn't a change: a package touched after it, over unsaved work, asks nothing.
    @Test func aSaveOfItsOwnIsNotAChange() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let document = try #require(tab.document)
        tab.session.addBlankLayer()
        try await eventually { document.hasUnsavedChanges }
        #expect(await document.autosave())
        try renameFirstLayer(in: tab)

        try await Task.detached {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { url in
                try? Data("synced".utf8).write(to: url.appending(path: "Sync Notes.txt"))
            }
            if let coordinationError { throw coordinationError }
        }.value
        try await Task.sleep(for: .seconds(1))
        #expect(!tab.session.changedOnDisk && !document.changeWaits)
        #expect(tab.session.document?.layers.first?.name == "Unsaved here")
        await tab.close()
    }

    /// A package that doesn't load, as one half written or broken by another app, is left alone, as on the Mac: the
    /// editor keeps what it has, nothing is said, and saving goes on. A good one after it is taken up.
    @Test func aPackageThatDoesntLoadIsLeftAlone() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let document = try #require(tab.document)
        let broken = try ProjectStore.package(for: try project(layers: 3))
        nonisolated(unsafe) let wrapper = broken
        try await Task.detached {
            var coordinationError: NSError?, writeError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
                do {
                    try? FileManager.default.removeItem(at: url)
                    try wrapper.write(to: url, options: [], originalContentsURL: nil)
                    // An image the manifest names is missing.
                    let images = url.appending(path: "images")
                    let first = try #require(try FileManager.default.contentsOfDirectory(atPath: images.path(percentEncoded: false)).first)
                    try FileManager.default.removeItem(at: images.appending(path: first))
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
        }.value
        try await eventually { document.changeWaits }
        try await eventually { !document.changeWaits }
        #expect(tab.session.document?.layers.count == 2)
        #expect(!tab.session.isProjectBusy && tab.session.saveError == nil && !tab.session.changedOnDisk)
        tab.session.addBlankLayer()
        try await eventually { document.hasUnsavedChanges }
        #expect(await document.autosave())

        try await writeElsewhere(url, layers: 4)
        try await eventually { tab.session.document?.layers.count == 4 }
        #expect(tab.session.document?.layers.count == 4)
        await tab.close()
    }

    /// A change made elsewhere waits for an edit under way to end, rather than pulling the project out from under it,
    /// as on the Mac; then it's taken up.
    @Test func aChangeElsewhereWaitsForAnEditInProgress() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        tab.session.beginTransform()
        #expect(tab.session.transformEdit != nil)

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.document?.changeWaits == true }
        try #require(tab.document?.changeWaits == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(tab.session.document?.layers.count == 2)
        #expect(tab.session.transformEdit != nil)

        tab.session.cancelTransform()
        try await eventually { tab.session.document?.layers.count == 3 }
        #expect(tab.session.document?.layers.count == 3)
        await tab.close()
    }

    /// A stroke is waited for too, though the editor doesn't announce when one ends.
    @Test func aChangeElsewhereWaitsForAStroke() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        tab.session.selectTool(.brush)
        tab.session.beginBrush(at: CGPoint(x: 20, y: 50))
        #expect(tab.session.brushStroke != nil)

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.document?.changeWaits == true }
        try #require(tab.document?.changeWaits == true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(tab.session.document?.layers.count == 2)
        #expect(tab.session.brushStroke != nil)

        // Taken back, as a second finger takes a stroke back: nothing unsaved, so the change goes in.
        tab.session.cancelBrush()
        try await eventually { tab.session.document?.layers.count == 3 }
        #expect(tab.session.document?.layers.count == 3)
        await tab.close()
    }

    /// A change taken up after text being typed was saved replaces that text in the file too: nothing is left to save,
    /// so the version just read isn't written back over the other app's.
    @Test func aChangeTakenUpAfterTypingLeavesNothingToSave() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let document = try #require(tab.document)
        tab.session.selectTool(.type)
        tab.session.beginText(at: CGPoint(x: 20, y: 20), newLayer: true)
        tab.session.textDraft?.style.content = "Hello"
        document.updateChangeCount(.done)
        #expect(await document.autosave())

        try await writeElsewhere(url, layers: 3)
        try await eventually { document.changeWaits }
        try #require(document.changeWaits)
        tab.session.cancelText()
        try await eventually { tab.session.document?.layers.count == 3 }
        try #require(tab.session.document?.layers.count == 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!document.hasUnsavedChanges)
        await tab.close()
    }

    /// A change that comes while the project opens, and is read only once the project is in, goes in as any other
    /// does: what was done in the editor meanwhile is asked about, not dropped.
    @Test func aChangeReadWhileTheProjectOpensAsksFirst() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = EditorSession()
        let document = CompositorDocument(fileURL: url, session: session)
        let changed = try ProjectStore.package(for: try project(layers: 3))
        var held = false, release: CheckedContinuation<Void, Never>?
        document.beforeReadingChange = {
            held = true
            await withCheckedContinuation { release = $0 }
        }
        try await document.openDocument { _ in
            // Written after the package was first read, found while the project opens, and read once it's in.
            try? FileManager.default.removeItem(at: url)
            try? changed.write(to: url, options: [], originalContentsURL: nil)
            document.revert(toContentsOf: url, completionHandler: nil)
            for _ in 0..<250 where !held { try? await Task.sleep(for: .milliseconds(20)) }
            return nil
        }
        try #require(held)
        document.beforeReadingChange = nil
        let first = try #require(session.document?.layers.first?.id)
        session.renameLayer(first, to: "Unsaved here")
        release?.resume()

        try await eventually { session.changedOnDisk }
        #expect(session.changedOnDisk)
        #expect(session.document?.layers.first?.name == "Unsaved here")
        document.answerChangeOnDisk(revert: false)
        await document.closeDocument()
    }

    /// With unsaved work, a change made elsewhere asks first, with the Mac's question, and nothing is lost meanwhile:
    /// the work stays in the editor, and the other version on disk, which no save writes over while it's asked.
    @Test func unsavedWorkIsNeverReplacedWithoutAsking() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        let document = try #require(tab.document)
        try renameFirstLayer(in: tab)

        try await writeElsewhere(url, layers: 3)
        try await eventually { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == changedOnDiskTitle)
        #expect(alert.actions.map(\.title) == ["Revert", "Keep Mine"])
        // Return reverts, as the Mac's default button does; Escape keeps what the editor has.
        #expect(alert.preferredAction?.title == "Revert" && alert.actions.map(\.style) == [.destructive, .cancel])
        // Save waits for the answer, as the Mac's sheet keeps it from saving.
        #expect(!controller.canPerformAction(#selector(EditorWindowController.saveProject(_:)), withSender: nil))
        #expect(!controller.canPerformAction(#selector(EditorWindowController.duplicateProject(_:)), withSender: nil))
        #expect(tab.session.document?.layers.first?.name == "Unsaved here")
        #expect(tab.session.isModified)
        _ = await document.autosave()
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 3)
        alert.dismiss(animated: false)
        tab.document?.answerChangeOnDisk(revert: true)
        await tab.close()
    }

    /// A question that comes while something else is over the window, as the share sheet or another alert, shows once
    /// that's gone.
    @Test func aQuestionWaitsForWhatsOverTheWindow() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        try renameFirstLayer(in: tab)
        let other = UIViewController()
        controller.present(other, animated: false)

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.changedOnDisk }
        try #require(tab.session.changedOnDisk)
        try await Task.sleep(for: .milliseconds(300))
        other.dismiss(animated: false)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == changedOnDiskTitle)
        controller.presentedViewController?.dismiss(animated: false)
        tab.document?.answerChangeOnDisk(revert: true)
        await tab.close()
    }

    /// A tab behind asks once it's brought forward, as on the Mac, keeping its work until then.
    @Test func aTabBehindAsksWhenBroughtForward() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        try renameFirstLayer(in: tab)
        controller.newCanvasTab(nil)
        #expect(controller.activeTab !== tab)

        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.changedOnDisk }
        try #require(tab.session.changedOnDisk)
        try await Task.sleep(for: .milliseconds(600))
        #expect(controller.presentedViewController == nil)
        #expect(tab.session.document?.layers.first?.name == "Unsaved here")

        controller.select(tab.id)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == changedOnDiskTitle)
        controller.presentedViewController?.dismiss(animated: false)
        tab.document?.answerChangeOnDisk(revert: true)
        await tab.close()
    }

    // MARK: The answer

    /// Revert takes up the version on disk, letting go of the unsaved work, as on the Mac.
    @Test func revertTakesUpTheVersionOnDisk() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        try renameFirstLayer(in: tab)
        try await writeElsewhere(url, layers: 3)
        try await eventually { controller.presentedViewController is UIAlertController }
        try #require(tab.session.changedOnDisk && controller.presentedViewController is UIAlertController)
        // As Revert does: answered once the question has gone.
        controller.presentedViewController?.dismiss(animated: false) { tab.document?.answerChangeOnDisk(revert: true) }
        try await eventually { controller.presentedViewController == nil }

        try await eventually { tab.session.document?.layers.count == 3 }
        #expect(tab.session.document?.layers.count == 3)
        #expect(tab.session.document?.layers.first?.name != "Unsaved here")
        #expect(!tab.session.isModified && !tab.session.changedOnDisk)
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.presentedViewController == nil)
        await tab.close()
    }

    /// Keep Mine keeps the unsaved work, and the next save writes it over the other version, as on the Mac.
    @Test func keepMineSavesOverIt() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        let document = try #require(tab.document)
        try renameFirstLayer(in: tab)
        try await writeElsewhere(url, layers: 3)
        try await eventually { controller.presentedViewController is UIAlertController }
        try #require(tab.session.changedOnDisk && controller.presentedViewController is UIAlertController)
        // As Keep Mine does: answered once the question has gone.
        controller.presentedViewController?.dismiss(animated: false) { document.answerChangeOnDisk(revert: false) }
        try await eventually { controller.presentedViewController == nil }

        try await eventually { !document.changeWaits }
        #expect(!tab.session.changedOnDisk)
        #expect(tab.session.document?.layers.first?.name == "Unsaved here")
        #expect(tab.session.isModified)
        #expect(await document.autosave())
        let saved = try ProjectStore.readPackage(url).manifest
        #expect(saved.layers.count == 2 && saved.layers.first?.name == "Unsaved here")
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.presentedViewController == nil)
        await tab.close()
    }

    /// A version that comes while the question is up is asked about too, once Keep Mine has kept the one asked
    /// about, as on the Mac: neither is written over without asking.
    @Test func aChangeWhileAskingIsAskedAboutToo() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let document = try #require(tab.document)
        try renameFirstLayer(in: tab)
        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.changedOnDisk }
        try #require(tab.session.changedOnDisk)

        try await writeElsewhere(url, layers: 4)
        try await Task.sleep(for: .milliseconds(300))
        document.answerChangeOnDisk(revert: false)
        try await eventually { !tab.session.changedOnDisk }
        try await eventually { tab.session.changedOnDisk }
        #expect(tab.session.changedOnDisk)
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 4)
        document.answerChangeOnDisk(revert: true)
        try await eventually { tab.session.document?.layers.count == 4 }
        #expect(tab.session.document?.layers.count == 4)
        await tab.close()
    }

    // MARK: Closing and saving meanwhile

    /// A tab that closes while its question waits keeps what the editor has, as Keep Mine would, and saves it over the
    /// other version, as the Mac's does when its window closes.
    @Test func closingWhileAChangeWaitsKeepsWhatTheEditorHas() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        try renameFirstLayer(in: tab)
        try await writeElsewhere(url, layers: 3)
        try await eventually { tab.session.changedOnDisk }
        try #require(tab.session.changedOnDisk)

        await tab.close()
        #expect(!tab.session.changedOnDisk)
        let saved = try ProjectStore.readPackage(url).manifest
        #expect(saved.layers.count == 2 && saved.layers.first?.name == "Unsaved here")
    }

    /// Save while a change waits for a transform keeps the transform, as the Mac's Save does, and lets the change ask;
    /// it doesn't say the save failed.
    @Test func savingWhileAChangeWaitsLetsItAsk() async throws {
        try await whileAChangeWaits { controller, tab in controller.saveProject(nil) }
    }

    /// Closing a tab while a change waits for a transform keeps the transform, as closing settles it, and lets the change
    /// ask; the tab stays for the answer, and doesn't say a save failed.
    @Test func closingWhileAChangeWaitsForAnEditLetsItAsk() async throws {
        try await whileAChangeWaits { controller, tab in controller.close(tab.id) }
    }

    /// Does `act` while a change made elsewhere waits for a transform, over unsaved work; then expects the question.
    private func whileAChangeWaits(_ act: (EditorWindowController, EditorTab) -> Void) async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let tab = try await opened(url, in: controller)
        let document = try #require(tab.document)
        try renameFirstLayer(in: tab)
        let active = try #require(tab.session.activeLayerID)
        tab.session.beginTransform()
        var moved = try #require(tab.session.transformEdit?.draft)
        moved.origin.x += 20
        tab.session.previewTransform(moved)
        try await writeElsewhere(url, layers: 3)
        try await eventually { document.changeWaits }
        try #require(document.changeWaits)

        act(controller, tab)
        try await eventually { controller.presentedViewController is UIAlertController }
        #expect((controller.presentedViewController as? UIAlertController)?.title == changedOnDiskTitle)
        #expect(tab.session.transformEdit == nil)
        #expect(tab.session.document?.layers.first { $0.id == active }?.transform == moved)
        #expect(controller.tabs.contains { $0 === tab } && controller.activeTab === tab)
        #expect(try ProjectStore.readPackage(url).manifest.layers.count == 3)
        controller.presentedViewController?.dismiss(animated: false)
        document.answerChangeOnDisk(revert: true)
        // Save, or the close, goes on once the change is settled.
        try await eventually { tab.session.document?.layers.count == 3 }
        #expect(tab.session.document?.layers.count == 3)
        await controller.saving?.value
        if controller.tabs.contains(where: { $0 === tab }) {
            try await eventually { !controller.tabs.contains { $0 === tab } || controller.saving == nil }
        }
        try await eventually { tab.document == nil || !controller.tabs.contains { $0 === tab } }
        if tab.document != nil, controller.tabs.contains(where: { $0 === tab }) { await tab.close() }
    }
}
