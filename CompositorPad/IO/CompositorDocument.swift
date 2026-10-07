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
    /// The saves over the file have failed since the last one that worked: only the first of them says why.
    private let failing = Mutex(false)
    /// Whether the save starting now says why it failed, through the editor. One made through `saveNow` leaves that to
    /// its caller.
    private let saysFailure = Mutex(true)
    /// Saving nothing more: what the project hasn't saved is let go as it closes.
    private let discarding = Mutex(false)
    /// Changes made elsewhere waiting to go in, or being read: saves wait while there are any, so neither version is
    /// lost before it's settled. Should iPadOS end the app meanwhile, what the editor hasn't saved is lost; the other
    /// version is kept.
    private let holds = Mutex(0)
    /// The last save was refused for a change made elsewhere on its way in.
    private let heldSave = Mutex(false)
    /// The project's images as its package holds them, so a save encodes only what changed.
    let encoded = EncodedImages()
    /// A URL from the Files app is the app's to use only between these calls; `open` starts, `closeDocument` stops.
    @MainActor private var accessedURL: URL?
    /// Told how far the open's own read has come. Cleared once `open` returns, so a read after it, as when something else
    /// changes the package, says nothing.
    private let reading: Mutex<(@Sendable (ProjectStore.ReadProgress) -> Void)?>

    init(fileURL url: URL, session: EditorSession, reading: (@Sendable (ProjectStore.ReadProgress) -> Void)? = nil) {
        self.session = session
        self.reading = Mutex(reading)
        super.init(fileURL: url)
    }

    // MARK: Opening and closing

    /// Reads the package and puts it into the editor. `prepare` is handed what was read, to make the canvas's textures
    /// for it away from the main thread; they go to the canvas in the same turn of the main actor as the project goes
    /// into the editor, so the canvas's next frame is the project's, and finds them. Returns how many went to the canvas.
    /// Cancelled meanwhile, it closes the file again and throws `CancellationError`, the editor untouched.
    @MainActor @discardableResult
    func openDocument(prepare: (ProjectSnapshot) async -> GPUCanvasRenderer.Prepared? = { _ in nil }) async throws -> Int {
        if fileURL.startAccessingSecurityScopedResource() { accessedURL = fileURL }
        let opened = await open()
        reading.withLock { $0 = nil }
        guard opened else {
            stopAccessing()
            throw lastError.withLock { $0 } ?? CocoaError(.fileReadUnknown)
        }
        guard var snapshot = takeReadSnapshot() else {
            _ = await close()
            stopAccessing()
            throw ProjectError.invalid
        }
        guard !Task.isCancelled else {
            await closeDocument()
            throw CancellationError()
        }
        var prepared = await prepare(snapshot)
        guard !Task.isCancelled else {
            await closeDocument()
            throw CancellationError()
        }
        // Something else wrote the package meanwhile: what it holds now goes in, and its first frame makes its own
        // textures.
        if let newer = takeReadSnapshot() {
            snapshot = newer
            prepared = nil
        }
        // Nothing is awaited from here to the install, so no frame comes between.
        if let prepared { GPUCanvasRenderer.shared?.adopt(prepared) }
        session.installProject(snapshot, from: fileURL)
        trackChanges()
        return prepared?.count ?? 0
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

    /// Saves what hasn't been, and lets go of the file. A change made elsewhere still waiting to go in is kept out, as
    /// Keep Mine keeps it, and what the editor has is saved over it.
    @MainActor func closeDocument() async {
        isClosing = true
        answerChangeOnDisk(revert: false)
        holds.withLock { $0 = 0 }
        // An edit made in this turn of the main actor, which hasn't marked the document changed yet, is saved too.
        if session.history.isModified { updateChangeCount(.done) }
        _ = await close()
        stopAccessing()
    }

    /// The package just read, if it hasn't been taken yet.
    private func takeReadSnapshot() -> ProjectSnapshot? {
        readSnapshot.withLock { value in defer { value = nil }; return value }
    }

    @MainActor private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    override func read(from url: URL) throws {
        let snapshot = try ProjectStore.readPackage(url, encoded: encoded, progress: reading.withLock { $0 })
        readSnapshot.withLock { $0 = snapshot }
        known.withLock { $0 = try? ProjectDigest.compute(for: url) }
    }

    override func handleError(_ error: any Error, userInteractionPermitted: Bool) {
        lastError.withLock { $0 = error }
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
    }

    // MARK: Saving

    /// Saves now, as Save asks. Throws why it couldn't, for the caller to say: the document doesn't say it too. A change
    /// made elsewhere on its way in is settled first: checked, and asked about if it has to be.
    @MainActor func saveNow() async throws {
        while true {
            await settleChange()
            saysFailure.withLock { $0 = false }
            heldSave.withLock { $0 = false }
            if await save(to: fileURL, for: .forOverwriting) { return }
            // Refused for a change noticed just now, which is settled first in turn.
            guard heldSave.withLock({ $0 }) else {
                throw lastError.withLock { $0 } ?? CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// Waits for every change made elsewhere on its way in to be settled: checked, and asked about if it has to be.
    @MainActor func settleChange() async {
        while changeWaits {
            _ = await takingUp?.value
            // One just noticed is on its way to the main actor.
            await Task.yield()
        }
    }

    /// Every save, asked for or UIDocument's own, from start to finish. One over the file that fails says why, through
    /// the editor, as every failed save does on the Mac; but only the first of a run of them, as UIDocument tries again
    /// on its own while there's something to save, until one works. A new project's first save is said by whoever made it.
    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let says = saysFailure.withLock { says in defer { says = true }; return says }
        // Nothing left to save, as far as the person is concerned.
        guard !discarding.withLock({ $0 }) else {
            completionHandler?(true)
            return
        }
        // Nothing is written over a change made elsewhere before it's settled.
        guard holds.withLock({ $0 }) == 0 else {
            heldSave.withLock { $0 = true }
            completionHandler?(false)
            return
        }
        let saving = Timing.begin("Save project")
        super.save(to: url, for: saveOperation) { [self] success in
            if success { Timing.end(saving) }
            if saveOperation == .forOverwriting {
                let first = failing.withLock { failing in defer { failing = !success }; return !failing }
                if !success, first, says {
                    // UIDocument has handled the error by now.
                    let message = (lastError.withLock { $0 } ?? CocoaError(.fileWriteUnknown)).localizedDescription
                    Task { @MainActor in session.saveError = message }
                }
            }
            completionHandler?(success)
        }
    }

    /// Saves nothing from now on, as Don't Save asks: what the project hasn't saved is let go as it closes.
    @MainActor func stopSaving() { discarding.withLock { $0 = true } }

    /// What a save writes: the document as its last finished edit left it, captured on the main queue. Edits carry on
    /// while it's written.
    override func contents(forType typeName: String) throws -> Any {
        let capturing = Timing.begin("Snapshot")
        let snapshot = try MainActor.assumeIsolated { () throws -> ProjectSnapshot in
            guard let snapshot = session.saveSnapshot() else { throw ProjectError.invalid }
            return snapshot
        }
        Timing.end(capturing)
        return snapshot
    }

    /// The package, written where it goes: what it holds is what the document knows of it now.
    override func writeContents(_ contents: Any, andAttributes additionalFileAttributes: [AnyHashable: Any]? = nil,
                                safelyTo url: URL, for saveOperation: UIDocument.SaveOperation) throws {
        try super.writeContents(contents, andAttributes: additionalFileAttributes, safelyTo: url, for: saveOperation)
        known.withLock { $0 = try? ProjectDigest.compute(for: url) }
    }

    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation,
                                originalContentsURL: URL?) throws {
        guard let snapshot = contents as? ProjectSnapshot else { throw ProjectError.invalid }
        let package = try ProjectStore.package(for: snapshot, quickLook: Self.quickLookImages(snapshot), encoded: encoded)
        try Timing.measure("Write package") { try package.write(to: url, options: [], originalContentsURL: originalContentsURL) }
    }

    /// The preview the Mac's Finder shows for the package. The exporter renders it on its own actor; the write is
    /// already on a background queue of UIDocument's, so it waits there for it.
    private static func quickLookImages(_ snapshot: ProjectSnapshot) -> QuickLookImages? {
        final class Box: @unchecked Sendable { var images: QuickLookImages? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        // At the save's own priority, which Task.currentPriority reads from the thread outside a task: waiting on a
        // semaphore raises nothing, as it has no owner.
        Task.detached(priority: Task.currentPriority) {
            box.images = await ImageExporter.shared.quickLookImages(snapshot)
            done.signal()
        }
        done.wait()
        return box.images
    }

    // MARK: Changes

    /// The file holds text that was being typed, as Done would put it: once that text is done with, by Done or Cancel,
    /// the project is to save again.
    @MainActor private var fileHoldsDraft = false

    /// Marks the document changed whenever the editor's history moves away from what was saved, and unchanged when
    /// undo takes it back, so UIDocument saves it when it should; and changed when text the file holds is done with.
    @MainActor private func trackChanges() {
        withObservationTracking {
            _ = session.history.currentRevision
            _ = session.textDraft == nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.documentState.contains(.closed) else { return }
                self.markChanges()
                self.trackChanges()
            }
        }
    }

    @MainActor private func markChanges() {
        let changed = session.history.isModified || (fileHoldsDraft && session.textDraft == nil)
        updateChangeCount(changed ? .done : .cleared)
    }

    /// A save made while text was being typed, which it wrote as Done would put it.
    private struct DraftSave { let revision: UUID }

    /// A save is of the history's revision when it began: once written, that revision is the saved one, and whatever
    /// the project has done since, edits or an undo back past it, is still to save. Text being typed is written too,
    /// and is to save again once it's done with.
    override func changeCountToken(for saveOperation: UIDocument.SaveOperation) -> Any {
        MainActor.assumeIsolated {
            let revision = session.history.currentRevision
            return session.textDraft == nil ? revision as Any : DraftSave(revision: revision)
        }
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: UIDocument.SaveOperation) {
        let saved: (revision: UUID, draft: Bool)
        switch changeCountToken {
        case let revision as UUID: saved = (revision, false)
        case let draft as DraftSave: saved = (draft.revision, true)
        default: return super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        }
        Task { @MainActor in
            session.history.markSaved(saved.revision)
            fileHoldsDraft = saved.draft
            markChanges()
        }
    }

    /// Something else wrote the package: the editor takes it up in place, keeping the view and the selected layers,
    /// as the Mac's does. Not in the middle of an edit, and not over unsaved work without asking.
    override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        // Nothing is written over it from now until it's settled.
        holds.withLock { $0 += 1 }
        Task { @MainActor in
            let success = await takeUpChange()
            completionHandler?(success)
        }
    }

    /// Something else changed the package. UIDocument reverts to it on its own only until the document first saves, so
    /// the document checks too.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        revert(toContentsOf: fileURL, completionHandler: nil)
    }

    /// What the package held when the document last read or wrote it, or kept what the editor has over it. Only a
    /// change to that counts, as on the Mac: a package that was only touched is left alone.
    private let known = Mutex<ProjectDigest?>(nil)

    /// What the package holds now, once UIDocument's own reading and writing is done; nil when it can't be told, as
    /// for a package caught half written, which waits for the next change.
    @MainActor private func packageOnDisk() async -> ProjectDigest? {
        await withCheckedContinuation { continuation in
            performAsynchronousFileAccess { [self] in
                continuation.resume(returning: try? ProjectDigest.compute(for: fileURL))
            }
        }
    }

    /// Changes made elsewhere go in one at a time, each once the one before is settled.
    @MainActor private var takingUp: Task<Bool, Never>?
    /// A change made elsewhere is on its way in: being checked, waiting for an edit to end or for the answer to whether
    /// to take it up, or being read.
    var changeWaits: Bool { holds.withLock { $0 } > 0 }
    /// The answer to whether to take up a change made elsewhere.
    @MainActor private var answer: CheckedContinuation<Bool, Never>?
    /// Closing: a change made elsewhere from now on is kept out.
    @MainActor private var isClosing = false
    /// Tests hold a change made elsewhere here: found to be one, and not yet read.
    @MainActor var beforeReadingChange: (() async -> Void)?

    /// Takes up the package, once the changes before it are settled and it can, unless it's kept out, and lets saves go
    /// on. False only when the package didn't load; true when it was taken up, kept out, or there was nothing new.
    @MainActor private func takeUpChange() async -> Bool {
        let previous = takingUp
        let current = Task { @MainActor in
            _ = await previous?.value
            defer { holds.withLock { $0 = max(0, $0 - 1) } }
            return await takeUp()
        }
        takingUp = current
        return await current.value
    }

    @MainActor private func takeUp() async -> Bool {
        guard !isClosing else { return true }
        // Only a real change counts.
        guard let onDisk = await packageOnDisk(), onDisk != known.withLock({ $0 }) else { return true }
        // Until the project is in the editor, the open takes up what's read itself.
        let inEditor = session.projectURL != nil
        if inEditor {
            guard await waitsAndAsks(countingAsSeen: true) else { return true }
            // The project is busy while it's read, as the Mac's is; an open is busy already.
            session.isProjectBusy = true
        }
        await beforeReadingChange?()
        let read = await readChange()
        if inEditor { session.isProjectBusy = false }
        guard let read else { return false }
        // Until the project is in the editor, the open takes up what was read itself.
        guard session.projectURL != nil else {
            readSnapshot.withLock { $0 = read }
            return true
        }
        // Read while the project opened, but too late for the open to take up: it goes in as any change made elsewhere
        // does. What was read is what's asked about.
        if !inEditor { guard await waitsAndAsks(countingAsSeen: false) else { return true } }
        // The file holds this now, not text it was saved with.
        fileHoldsDraft = false
        session.reloadProject(read)
        return true
    }

    /// Reads the package from wherever it is now, moved meanwhile or not, coordinated with other apps as UIDocument's
    /// own reading is, once that's done. Not through UIDocument's revert, which closes a document whose package doesn't
    /// load: one that doesn't is left alone, as on the Mac, and the next change is checked afresh.
    @MainActor private func readChange() async -> ProjectSnapshot? {
        await withCheckedContinuation { continuation in
            performAsynchronousFileAccess { [self] in
                var read: ProjectSnapshot?, coordinationError: NSError?
                NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
                    guard let snapshot = try? ProjectStore.readPackage(url, encoded: encoded) else { return }
                    read = snapshot
                    known.withLock { $0 = try? ProjectDigest.compute(for: url) }
                }
                continuation.resume(returning: read)
            }
        }
    }

    /// Waits for an edit under way to end, as the Mac's watch does, and with unsaved work asks whether to take the change
    /// up. False when it's kept out, or the document closes meanwhile. Keep Mine counts the version asked about as seen,
    /// as the Mac's watch does, so the next save writes over it; `countingAsSeen` is off when what was read already is.
    @MainActor private func waitsAndAsks(countingAsSeen counts: Bool) async -> Bool {
        // Checked again four times a second; the Mac's watch backs off instead, as its check reads the package. A
        // stroke ending, or the project no longer being busy, isn't something the editor announces.
        while session.hasEditInProgress, !isClosing {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !isClosing else { return false }
        guard session.isModified else { return true }
        let asked = counts ? await packageOnDisk() : nil
        guard !isClosing else { return false }
        session.changedOnDisk = true
        let reverts = await withCheckedContinuation { answer = $0 }
        session.changedOnDisk = false
        if !reverts, let asked { known.withLock { $0 = asked } }
        return reverts
    }

    /// The answer to whether to take up a change made elsewhere: Revert takes it up, letting go of the unsaved work;
    /// Keep Mine keeps the work, and the next save writes it over the other version, as on the Mac.
    @MainActor func answerChangeOnDisk(revert: Bool) {
        answer?.resume(returning: revert)
        answer = nil
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
        // Saved first, so the copy has everything the editor holds; then copied from wherever it is by then.
        try await saveNow()
        let destination = Self.unusedURL(named: localizedName + " copy")
        let source = fileURL
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
