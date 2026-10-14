import Foundation
import Testing
@testable import Compositor

/// The projects the iPad app remembers, a window's tabs and Open Recent, are found again after a relaunch.
@MainActor struct PadProjectReferenceTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "PadProjectReferenceTests-\(UUID().uuidString)")

    private func same(_ a: URL?, _ b: URL) -> Bool {
        func path(_ url: URL) -> String {
            url.resolvingSymlinksInPath().path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return a.map(path) == path(b)
    }

    /// Reinstalling or updating the app puts its Documents folder somewhere new, as a copy, and saving a project
    /// replaces its package: a bookmark made before both points at neither the path nor the file.
    @Test func findsItsOwnProjectAfterSavingAndReinstalling() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appending(path: "A/Documents"), after = root.appending(path: "B/Documents")
        let project = before.appending(path: "Night Harbor.comp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let reference = try #require(PadRecentProjects.reference(to: project, in: before))

        try FileManager.default.removeItem(at: project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "B"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: before, to: after)
        try FileManager.default.removeItem(at: root.appending(path: "A"))

        #expect(same(PadRecentProjects.resolve(reference, in: after), after.appending(path: "Night Harbor.comp")))
    }

    /// A project elsewhere, as Files hands them over, is kept by a bookmark, which carries the permission to open it.
    @Test func findsAProjectElsewhereByItsBookmark() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents")
        let project = root.appending(path: "Elsewhere/Moon.comp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let reference = try #require(PadRecentProjects.reference(to: project, in: documents))

        #expect(same(PadRecentProjects.resolve(reference, in: documents), project))
    }

    /// A project deleted since is left out, rather than opened as nothing.
    @Test func leavesOutAProjectDeletedSince() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents")
        let project = documents.appending(path: "Gone.comp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let reference = try #require(PadRecentProjects.reference(to: project, in: documents))
        try FileManager.default.removeItem(at: project)

        #expect(PadRecentProjects.resolve(reference, in: documents) == nil)
    }
}
