import Foundation
import Testing
import UIKit
@testable import Compositor

/// Saving a project on iPad, and saying why when it can't be, as the Mac does.
@MainActor struct PadSaveTests {
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

    /// A project of one layer in a folder of its own, opened in the tab in front.
    private func openedTab(in controller: EditorWindowController) async throws -> (tab: EditorTab, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PadSaveTests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let session = EditorSession()
        session.createNewProject(width: 200, height: 100)
        let url = folder.appending(path: "Project.comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        // Through the tab, so the app's recent projects don't keep it.
        let tab = try #require(controller.activeTab)
        _ = try await tab.open(url).value
        try #require(tab.document != nil)
        return (tab, folder)
    }

    /// Makes every save into `folder` fail, as a full disk or a folder the app may no longer write would: the folder is
    /// made read-only. The function returned makes it writable again.
    private func failSaves(in folder: URL) throws -> () throws -> Void {
        let path = folder.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        return { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    private func removeAll(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: folder)
    }

    /// Waits up to a few seconds for `condition`, as the document's and the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// An edit the document has been told of, so an autosave saves it.
    private func edit(_ tab: EditorTab) async throws {
        tab.session.addBlankLayer()
        try await eventually { tab.document?.hasUnsavedChanges == true }
    }

    /// The alert over the window, once one shows.
    private func alert(over controller: EditorWindowController) async throws -> UIAlertController? {
        try await eventually { controller.presentedViewController is UIAlertController }
        return controller.presentedViewController as? UIAlertController
    }

    private func dismissAlert(over controller: EditorWindowController) async throws {
        controller.presentedViewController?.dismiss(animated: false)
        try await eventually { controller.presentedViewController == nil }
    }

    /// The error's own words, as the read-only folder gives them: they name the file, unlike the words said when there's
    /// no error to tell.
    private func isTheErrorsOwnWords(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.contains("Project.comp") && message != CocoaError(.fileWriteUnknown).localizedDescription
    }

    /// A save UIDocument makes on its own that fails says why, as every failed save does on the Mac, with the Mac's
    /// title and the error's own words. It says so once, not again each time UIDocument tries, until a save works.
    @Test func aFailedAutosaveSaysWhyOnceUntilASaveWorks() async throws {
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let (tab, folder) = try await openedTab(in: controller)
        defer { removeAll(folder) }
        let document = try #require(tab.document)

        var restore = try failSaves(in: folder)
        try await edit(tab)
        #expect(await document.autosave() == false)
        let said = try #require(try await alert(over: controller))
        #expect(said.title == "Couldn’t save the project")
        #expect(isTheErrorsOwnWords(said.message))
        try await dismissAlert(over: controller)

        // Failing again says nothing.
        try await edit(tab)
        #expect(await document.autosave() == false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.presentedViewController == nil)

        // Once a save works, the next failure says so again.
        try restore()
        try await edit(tab)
        #expect(await document.autosave())
        restore = try failSaves(in: folder)
        try await edit(tab)
        #expect(await document.autosave() == false)
        #expect(try await alert(over: controller)?.title == "Couldn’t save the project")
        try await dismissAlert(over: controller)
        try restore()
        await tab.close()
    }

    /// Save says why it failed, every time, as the Mac's does: in the error's own words, once for each Save.
    @Test func saveSaysWhyItFailed() async throws {
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let (tab, folder) = try await openedTab(in: controller)
        defer { removeAll(folder) }

        let restore = try failSaves(in: folder)
        try await edit(tab)
        for _ in 0..<2 {
            controller.saveProject(nil)
            let said = try #require(try await alert(over: controller))
            #expect(said.title == "Couldn’t save the project")
            #expect(isTheErrorsOwnWords(said.message))
            try await dismissAlert(over: controller)
            // Once.
            try await Task.sleep(for: .milliseconds(500))
            #expect(controller.presentedViewController == nil)
        }
        try restore()
        await tab.close()
    }

    /// A tab whose project can't be saved as it closes stays, with its work, and says why, as the Mac's close does
    /// when its Save fails; Don't Save then closes it, as on the Mac.
    @Test func closingATabWhoseSaveFailsKeepsIt() async throws {
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let (tab, folder) = try await openedTab(in: controller)
        defer { removeAll(folder) }

        let restore = try failSaves(in: folder)
        try await edit(tab)
        let layers = tab.session.document?.layers.count
        controller.close(tab.id)
        let said = try #require(try await alert(over: controller))
        #expect(said.title == "Couldn’t save the project")
        #expect(controller.tabs.contains { $0 === tab } && controller.activeTab === tab)
        #expect(tab.session.document?.layers.count == layers)
        #expect(said.actions.map(\.title) == ["Don’t Save", "Cancel"])
        try await dismissAlert(over: controller)

        // Don't Save, as its button does.
        try restore()
        let url = try #require(tab.document?.fileURL)
        controller.closeWithoutSaving(tab.id)
        #expect(!controller.tabs.contains { $0 === tab })
        try await eventually { tab.document == nil }
        #expect(tab.document == nil)
        let saved = try ProjectStore.readPackage(url)
        #expect(saved.manifest.layers.count == 1)
    }

    /// Duplicate stops, saying why, when the save before its copy fails, rather than copying what was saved last.
    @Test func duplicateStopsWhenItsSaveFails() async throws {
        let controller = EditorWindowController()
        let window = try window(showing: controller)
        defer { window.isHidden = true }
        let (tab, folder) = try await openedTab(in: controller)
        defer { removeAll(folder) }
        let copy = CompositorDocument.unusedURL(named: "Project copy")
        defer { try? FileManager.default.removeItem(at: copy) }

        let restore = try failSaves(in: folder)
        try await edit(tab)
        controller.duplicateProject(nil)
        let said = try #require(try await alert(over: controller))
        #expect(said.title == "Couldn’t duplicate the project")
        #expect(isTheErrorsOwnWords(said.message))
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
        #expect(controller.tabs.count == 1)
        try await dismissAlert(over: controller)
        try restore()
        await tab.close()
    }
}

