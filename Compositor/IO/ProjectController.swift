import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    private var saveGeneration = 0
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        let prepared = await prepareSave(asNew: asNew)
        // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
        // while the package is written in the background, as in Photoshop.
        session.isProjectBusy = false
        guard let prepared else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    private var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = localized("Export PNG")
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await ImageExporter.shared.exportPNG(snapshot, to: url) }
        catch { await showError(localized("Couldn’t export PNG"), error: error) }
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = localized("Canvas Size")
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, foreground: session.foregroundColor, background: session.backgroundColor) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            session.applyDocumentSize(resized, actionName: "Canvas Size")
        } catch { await showError(localized("Couldn’t change canvas size"), error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = localized("Image Size")
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            session.applyImageSize(resized)
        } catch { await showError(localized("Couldn’t resize the image"), error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = localized("Trim")
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            session.applyDocumentSize(resized, actionName: "Trim")
        } catch { await showError(localized("Couldn’t trim image"), error: error) }
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: Data? = await withCheckedContinuation { continuation in
                let sheet = NSWindow()
                sheet.styleMask = [.titled, .fullSizeContentView]
                sheet.title = localized("Export JPEG")
                sheet.contentViewController = NSHostingController(rootView: JPEGExportSheet(raster: raster) { data in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    // Release the hosted view and its closure after dismissal.
                    sheet.contentViewController = nil
                    continuation.resume(returning: data)
                })
                window.beginSheet(sheet)
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = localized("Export JPEG")
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(data, to: url)
        } catch { await showError(localized("Couldn’t export JPEG"), error: error) }
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return true }
        guard let prepared = await prepareSave(asNew: asNew) else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The document as it is now, and where it goes: asks with the Save panel when it has no file yet (or Save As).
    private func prepareSave(asNew: Bool) async -> (snapshot: ProjectSnapshot, destination: URL, revision: UUID)? {
        let revision = session.history.currentRevision
        guard let snapshot = session.projectSnapshot() else { return nil }
        var destination = asNew ? nil : session.projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.comp"
            panel.title = localized(asNew ? "Save Project As" : "Save Project")
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return nil }
            destination = url
        }
        guard let destination else { return nil }
        return (snapshot, destination, revision)
    }

    /// Writes a captured document in the background. Only that captured version counts as saved.
    private func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Our own save changes the package too; the watch ignores events until the saved bytes are remembered.
            externalChanges.saving = true
            defer { externalChanges.saving = false }
            do {
                try await ProjectStore.shared.save(snapshot, to: destination)
                session.projectURL = destination
                session.history.markSaved(revision)
                saveGeneration += 1
                NSDocumentController.shared.noteNewRecentDocumentURL(destination)
                await rememberProjectDigest(for: destination)
                watchProject(at: destination)
                return true
            } catch {
                await showError(localized("Couldn’t save the project"), error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = localized("Open Project")
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
            }
            session.installProject(snapshot, from: source)
            NSDocumentController.shared.noteNewRecentDocumentURL(source)
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError(localized("Couldn’t open the project"), error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject(); stopWatchingProject() }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed {
            session.clearProject()
            stopWatchingProject()
            window.close()
        }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to \(session.projectURL?.lastPathComponent ?? localized("Untitled"))?")
        alert.informativeText = localized("Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: localized("Save"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.addButton(withTitle: localized("Don’t Save"))
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    private func showError(_ title: String, error: Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized(title)
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: localized("OK"))
        _ = await show(alert)
    }

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError(localized("Open one project at a time"), error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}
