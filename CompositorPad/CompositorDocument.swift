import Synchronization
import UIKit

/// A .comp project open on iPad. UIDocument coordinates reading and writing the package with other apps and iCloud,
/// saves it on its own as it changes, and notices when something else changes it. The reading and writing themselves
/// are ProjectStore's, the same code and validation as the Mac's.
///
/// UIDocument calls its hooks on queues of its choosing: the package is read and written in the background, and the
/// document is captured for a save on the main queue, where the editor lives.
nonisolated final class CompositorDocument: UIDocument, @unchecked Sendable {
    /// The editor holding the document. Only the main actor touches it.
    let session: EditorSession
    /// A package just read, waiting for the main actor to put it into the editor.
    private let readSnapshot = Mutex<ProjectSnapshot?>(nil)
    /// Why the last open or save failed, for saying so.
    private let lastError = Mutex<(any Error)?>(nil)
    /// A URL from the Files app is the app's to use only between these calls; `open` starts, `closeDocument` stops.
    @MainActor private var accessedURL: URL?

    init(fileURL url: URL, session: EditorSession) {
        self.session = session
        super.init(fileURL: url)
    }

    // MARK: Opening and closing

    /// Reads the package and puts it into the editor. Cancelled meanwhile, it closes the file again and throws
    /// `CancellationError`, the editor untouched.
    @MainActor func openDocument() async throws {
        if fileURL.startAccessingSecurityScopedResource() { accessedURL = fileURL }
        guard await open() else {
            stopAccessing()
            throw lastError.withLock { $0 } ?? CocoaError(.fileReadUnknown)
        }
        guard let snapshot = readSnapshot.withLock({ value in defer { value = nil }; return value }) else {
            _ = await close()
            stopAccessing()
            throw ProjectError.invalid
        }
        guard !Task.isCancelled else {
            await closeDocument()
            throw CancellationError()
        }
        session.installProject(snapshot, from: fileURL)
        trackChanges()
    }

    /// A new project with what `session` already holds, written to `url` before anything else happens to it.
    @MainActor static func create(at url: URL, with session: EditorSession) async throws -> CompositorDocument {
        let document = CompositorDocument(fileURL: url, session: session)
        session.projectURL = url
        guard await document.save(to: url, for: .forCreating) else {
            session.projectURL = nil
            throw document.lastError.withLock { $0 } ?? CocoaError(.fileWriteUnknown)
        }
        document.trackChanges()
        return document
    }

    /// Saves what hasn't been, and lets go of the file.
    @MainActor func closeDocument() async {
        _ = await close()
        stopAccessing()
    }

    @MainActor private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    override func read(from url: URL) throws {
        let snapshot = try ProjectStore.readPackage(url)
        readSnapshot.withLock { $0 = snapshot }
    }

    override func handleError(_ error: any Error, userInteractionPermitted: Bool) {
        lastError.withLock { $0 = error }
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }

    // MARK: Saving

    /// Every save, asked for or UIDocument's own, from start to finish.
    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let saving = Timing.begin("Save project")
        super.save(to: url, for: saveOperation) { success in
            if success { Timing.end(saving) }
            completionHandler?(success)
        }
    }

    /// What a save writes: the document as it stands, captured on the main queue. Edits carry on while it's written.
    override func contents(forType typeName: String) throws -> Any {
        let capturing = Timing.begin("Snapshot")
        let snapshot = try MainActor.assumeIsolated { () throws -> ProjectSnapshot in
            guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
            return snapshot
        }
        Timing.end(capturing)
        return snapshot
    }

    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation,
                                originalContentsURL: URL?) throws {
        guard let snapshot = contents as? ProjectSnapshot else { throw ProjectError.invalid }
        let package = try ProjectStore.package(for: snapshot, quickLook: Self.quickLookImages(snapshot))
        try Timing.measure("Write package") { try package.write(to: url, options: [], originalContentsURL: originalContentsURL) }
    }

    /// The preview the Mac's Finder shows for the package. The exporter renders it on its own actor; the write is
    /// already on a background queue of UIDocument's, so it waits there for it.
    private static func quickLookImages(_ snapshot: ProjectSnapshot) -> QuickLookImages? {
        final class Box: @unchecked Sendable { var images: QuickLookImages? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.images = await ImageExporter.shared.quickLookImages(snapshot)
            done.signal()
        }
        done.wait()
        return box.images
    }

    // MARK: Changes

    /// Marks the document changed whenever the editor's history moves away from what was saved, and unchanged when
    /// undo takes it back, so UIDocument saves it when it should.
    @MainActor private func trackChanges() {
        withObservationTracking { _ = session.history.currentRevision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.documentState.contains(.closed) else { return }
                self.updateChangeCount(self.session.history.isModified ? .done : .cleared)
                self.trackChanges()
            }
        }
    }

    /// A save is of the history's revision when it began: once written, that revision is the saved one, and whatever
    /// the project has done since, edits or an undo back past it, is still to save.
    override func changeCountToken(for saveOperation: UIDocument.SaveOperation) -> Any {
        MainActor.assumeIsolated { session.history.currentRevision }
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: UIDocument.SaveOperation) {
        guard let saved = changeCountToken as? UUID else {
            return super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        }
        Task { @MainActor in
            session.history.markSaved(saved)
            updateChangeCount(session.history.isModified ? .done : .cleared)
        }
    }

    /// Something else wrote the package: the editor takes it up in place, keeping the view and the selected layers,
    /// as the Mac's does.
    override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        super.revert(toContentsOf: url) { [weak self] success in
            Task { @MainActor [weak self] in
                if success, let self, let snapshot = self.readSnapshot.withLock({ value in defer { value = nil }; return value }) {
                    self.session.reloadProject(snapshot)
                }
                completionHandler?(success)
            }
        }
    }

    // MARK: The file

    /// Renames the package where it is.
    @MainActor func rename(to name: String) async throws {
        let destination = fileURL.deletingLastPathComponent().appending(path: name + ".comp", directoryHint: .isDirectory)
        guard destination != fileURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let source = fileURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            performAsynchronousFileAccess {
                // The document is the presenter doing the move, so it's told of it below rather than by the coordinator.
                let coordinator = NSFileCoordinator(filePresenter: self)
                var coordinationError: NSError?, moveError: Error?
                coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                                       options: .forReplacing, error: &coordinationError) { from, to in
                    do {
                        coordinator.item(at: from, willMoveTo: to)
                        try FileManager.default.moveItem(at: from, to: to)
                        coordinator.item(at: from, didMoveTo: to)
                    } catch { moveError = error }
                }
                if let error = coordinationError ?? moveError { continuation.resume(throwing: error); return }
                self.presentedItemDidMove(to: destination)
                continuation.resume()
            }
        }
        session.projectURL = fileURL
    }

    /// Moved, here or by another app (renamed in Files, say): the editor, and so the tab, follows it.
    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        Task { @MainActor in session.projectURL = newURL }
    }

    /// A copy of the package beside the app's own projects, named after this one.
    @MainActor func duplicate() async throws -> URL {
        let duplicating = Timing.begin("Duplicate project")
        let destination = Self.unusedURL(named: localizedName + " copy")
        let source = fileURL
        // Saved first, so the copy has everything the editor holds.
        _ = await save(to: fileURL, for: .forOverwriting)
        let copying = Timing.begin("Copy package")
        try await Task.detached {
            var coordinationError: NSError?, copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { from in
                do { try FileManager.default.copyItem(at: from, to: destination) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
        }.value
        Timing.end(copying)
        Timing.end(duplicating)
        return destination
    }

    /// Where new projects go: the app's Documents folder, which Files shows as On My iPad › Compositor.
    static var projectsFolder: URL { URL.documentsDirectory }

    /// A free name there: “Untitled.comp”, then “Untitled 2.comp” and on.
    static func unusedURL(named name: String) -> URL {
        var candidate = projectsFolder.appending(path: name + ".comp", directoryHint: .isDirectory)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = projectsFolder.appending(path: "\(name) \(number).comp", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }
}
