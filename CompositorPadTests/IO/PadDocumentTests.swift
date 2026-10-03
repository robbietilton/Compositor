import Foundation
import Testing
import UIKit
@testable import Compositor

/// A tab's project and its file on iPad.
@MainActor struct PadDocumentTests {
    /// A new canvas is written to its file as it's made, so the file is where the project starts, as an opened
    /// project's does: undo doesn't take the tab back to no canvas at all, and a file with nothing left to save.
    @Test func aNewCanvasStartsFromItsFile() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let url = try #require(tab.document?.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!tab.session.canUndo)
        tab.session.undo()
        #expect(tab.session.document?.layers.count == 1)
        #expect(!tab.session.isModified)
        await tab.close()
    }

    /// An undo back to what the file had, made while a save was still writing the edit it undoes, leaves the file
    /// behind the project: the document still has it to save, so it's saved when the app goes to the background.
    @Test func anUndoDuringASaveIsStillSaved() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        try await tab.createDocument(named: "PadDocumentTests \(UUID().uuidString)")
        let document = try #require(tab.document)
        defer { try? FileManager.default.removeItem(at: document.fileURL) }
        func settle() async { for _ in 0..<20 { await Task.yield() } }

        tab.session.addBlankLayer()
        await settle()
        #expect(document.hasUnsavedChanges, "the edit")
        // A save of the new layer begins; before it's written, undo takes the layer away again.
        let saving = document.changeCountToken(for: .forOverwriting)
        tab.session.undo()
        await settle()
        #expect(!document.hasUnsavedChanges, "back to the file")
        // The save writes the layer, which the project no longer has.
        document.updateChangeCount(withToken: saving, for: .forOverwriting)
        await settle()
        #expect(tab.session.isModified)
        #expect(document.hasUnsavedChanges, "the undo")
        await tab.close()
    }
}
