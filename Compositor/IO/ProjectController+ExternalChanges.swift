import AppKit

/// Keeps an open project in step with its package on disk. When something else writes the package, the document
/// is reloaded in place: same tab, same viewport, same selection where the layers still exist. Only a real change
/// in content counts; a package that was merely touched, or one caught half written, is left alone with no message.
/// Unsaved work is never replaced without asking.
extension ProjectController {
    /// Starts (or restarts) watching the project the session has open. Called after a successful open and after
    /// every save, so the digest of the package on disk is always the one we last read or wrote.
    func watchProject(at url: URL) {
        guard url != externalChanges.watcher?.url else { return }
        externalChanges.watcher = ProjectWatcher(url: url) { [weak self] in self?.noteExternalChange() }
    }

    func stopWatchingProject() {
        externalChanges.watcher = nil
        externalChanges.knownDigest = nil
        externalChanges.recheck?.cancel()
        externalChanges.recheck = nil
        externalChanges.pending = false
    }

    /// Remembers the package as it is now, so the next event compares against it.
    func rememberProjectDigest(for url: URL) async {
        externalChanges.knownDigest = await Task.detached(priority: .utility) { try? ProjectDigest.compute(for: url) }.value
    }

    /// The tab came to the front: a change that arrived while it had unsaved work and was hidden can be asked about now.
    func resumeExternalChangeCheck() {
        if externalChanges.pending { noteExternalChange() }
    }

    private func noteExternalChange() {
        externalChanges.pending = true
        guard !externalChanges.checking else { return }
        Task { await checkExternalChange() }
    }

    private func checkExternalChange() async {
        externalChanges.checking = true
        defer { externalChanges.checking = false }
        while externalChanges.pending {
            externalChanges.pending = false
            guard let url = session.projectURL, session.document != nil, !externalChanges.saving else { return }
            // Compare content, not modification dates: sync clients touch metadata without changing anything.
            guard let digest = await Task.detached(priority: .utility) { try? ProjectDigest.compute(for: url) }.value,
                  digest != externalChanges.knownDigest else { continue }
            // Wait for an edit in progress to finish rather than pulling the document out from under it.
            guard session.canStartProjectOperation, session.transformEdit == nil, workspace?.isManaging != true else {
                scheduleRecheck(); return
            }
            if session.isModified {
                guard let window, isFrontmost else { externalChanges.pending = true; return }
                guard await askToRevert(in: window) else { externalChanges.knownDigest = digest; continue }
            }
            await reloadFromDisk(url)
        }
    }

    private var isFrontmost: Bool { workspace.map { $0.current.controller === self } ?? true }

    /// Retries while the session is busy, backing off so a long operation is not polled.
    private func scheduleRecheck() {
        externalChanges.pending = true
        externalChanges.recheck?.cancel()
        let attempt = externalChanges.recheckAttempt
        externalChanges.recheckAttempt = min(attempt + 1, 7)
        externalChanges.recheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
            guard let self, !Task.isCancelled else { return }
            self.noteExternalChange()
        }
    }

    private func reloadFromDisk(_ url: URL) async {
        externalChanges.recheckAttempt = 0
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }
        // Loading runs off the main thread, as an open does. A package that fails to load, half written or
        // mid-sync, leaves the open document alone; the next change on disk is checked afresh.
        guard let snapshot = try? await ProjectStore.shared.load(from: url) else { return }
        guard session.projectURL == url, session.document != nil else { return }
        session.reloadProject(snapshot)
        // Remember the package as loaded, not as first seen: it may have changed again while a sheet was up.
        await rememberProjectDigest(for: url)
        externalChanges.reloadCount += 1
    }

    private func askToRevert(in window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(session.projectURL?.lastPathComponent ?? "Untitled")” was changed on disk.")
        alert.informativeText = String(localized: "Another app changed this project. You can revert to the version on disk, losing your unsaved changes, or keep what you have.")
        alert.addButton(withTitle: String(localized: "Revert"))
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

/// The controller's bookkeeping for the watch: what the package looked like when last read or written, and
/// whether a check is running, waiting, or deferred because a save of our own is in flight.
@MainActor
final class ExternalChangeState {
    var watcher: ProjectWatcher?
    var knownDigest: ProjectDigest?
    var checking = false
    var pending = false
    var saving = false
    var recheck: Task<Void, Never>?
    var recheckAttempt = 0
    /// Reloads performed because the package changed on disk. Read by tests.
    var reloadCount = 0
}
