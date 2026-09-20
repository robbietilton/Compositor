import AppKit
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    private var saveGeneration = 0
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
        guard session.document != nil, begin() else { return false }
        defer { session.isProjectBusy = false }
        return await saveCurrent(asNew: asNew)
    }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await ImageExporter.shared.exportPNG(snapshot, to: url) }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Canvas Size"
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
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Image Size"
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
        } catch { await showError("Couldn’t resize the image", error: error) }
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
                sheet.title = "Export JPEG"
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
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(data, to: url)
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard let snapshot = session.projectSnapshot() else { return true }
        var destination = asNew ? nil : session.projectURL
        if destination == nil {
            let panel = NSSavePanel()
            let current = session.projectURL
            let format = current?.isPhotoshopDocument == true ? SaveFormat.photoshop : .compositor
            let picker = SaveFormatPicker(format: format, panel: panel)
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = asNew ? "Save As" : "Save"
            panel.nameFieldStringValue = SaveFormatPicker.filename(
                current?.deletingPathExtension().lastPathComponent ?? "Untitled", format: format)
            picker.apply()
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            withExtendedLifetime(picker) {}
            guard response == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let destination else { return false }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try await saveSnapshot(snapshot, to: destination)
            session.projectURL = destination
            session.history.markSaved()
            saveGeneration += 1
            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            return true
        } catch {
            await showError("Couldn’t save the document", error: error)
            return false
        }
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            source = await ProjectFilePanel.pick(window: window, multiple: false).first
            guard source != nil else { return false }
        }
        guard let source else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await loadSnapshot(from: source)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await loadSnapshot(from: source)
            }
            session.installProject(snapshot, from: source)
            NSDocumentController.shared.noteNewRecentDocumentURL(source)
            return true
        } catch {
            await showError("Couldn’t open the document", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject() }
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
            window.close()
        }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        guard session.isModified, session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    private func showError(_ title: String, error: Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
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
            let projects = urls.filter(\.isProjectDocument)
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { !$0.isProjectDocument },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }

    private func loadSnapshot(from url: URL) async throws -> ProjectSnapshot {
        if url.hasPhotoshopFilename || url.hasPhotoshopSignature {
            return try await PSDCodec.shared.load(from: url)
        }
        return try await ProjectStore.shared.load(from: url)
    }

    private func saveSnapshot(_ snapshot: ProjectSnapshot, to url: URL) async throws {
        if url.isPhotoshopDocument { try await PSDCodec.shared.save(snapshot, to: url) }
        else { try await ProjectStore.shared.save(snapshot, to: url) }
    }
}

/// Open includes `public.image` so Photoshop files on disk are enabled; `.comp` packages stay listed too.
enum ProjectFilePanel {
    @MainActor
    static func pick(window: NSWindow?, multiple: Bool) async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.treatsFilePackagesAsDirectories = false
        panel.title = "Open"
        panel.allowedContentTypes = UTType.projectOpenTypes
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK else { return [] }
        return panel.urls
    }
}

enum SaveFormat: Int {
    case compositor, photoshop
    var contentType: UTType { self == .photoshop ? .photoshopDocument : .compositorProject }
    var pathExtension: String { self == .photoshop ? "psd" : "comp" }
}

/// Format control for Save As. Installed as the panel accessory, then moved into the
/// button row between New Folder and Cancel once the panel is on screen.
@MainActor
final class SaveFormatPicker: NSObject {
    private let control: NSSegmentedControl
    let view: NSView
    weak var panel: NSSavePanel?
    private(set) var format: SaveFormat

    init(format: SaveFormat, panel: NSSavePanel) {
        self.format = format
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.setLabel("Compositor (.comp)", forSegment: 0)
        control.setLabel("Photoshop (.PSD)", forSegment: 1)
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.selectedSegment = format.rawValue
        control.controlSize = .small
        control.sizeToFit()
        self.control = control
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            stack.topAnchor.constraint(equalTo: wrap.topAnchor),
            stack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            wrap.heightAnchor.constraint(equalToConstant: 28)
        ])
        view = wrap
        super.init()
        control.target = self
        control.action = #selector(changed)
        panel.accessoryView = wrap
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidAppear), name: NSWindow.didBecomeKeyNotification, object: panel)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    static func filename(_ base: String, format: SaveFormat) -> String {
        let trimmed = (base as NSString).deletingPathExtension
        let name = trimmed.isEmpty ? "Untitled" : trimmed
        return "\(name).\(format.pathExtension)"
    }

    func apply() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = Self.filename(panel.nameFieldStringValue, format: format)
    }

    @objc private func changed() {
        format = SaveFormat(rawValue: control.selectedSegment) ?? .compositor
        apply()
    }

    @objc private func panelDidAppear() {
        DispatchQueue.main.async { [weak self] in self?.insertIntoButtonRow() }
    }

    /// Prefer the empty span on the button row (New Folder … Cancel) over the accessory strip.
    private func insertIntoButtonRow() {
        guard let panel, let content = panel.contentView, view.superview != nil else { return }
        guard let newFolder = button(titled: "New Folder", in: content),
              let cancel = button(titled: "Cancel", in: content),
              let row = commonSuperview(newFolder, cancel),
              view.superview !== row else { return }
        view.removeFromSuperview()
        panel.accessoryView = nil
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerYAnchor.constraint(equalTo: newFolder.centerYAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: newFolder.trailingAnchor, constant: 12),
            view.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            view.centerXAnchor.constraint(equalTo: row.centerXAnchor)
        ])
    }

    private func button(titled title: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.title == title { return button }
        for child in root.subviews {
            if let match = button(titled: title, in: child) { return match }
        }
        return nil
    }

    private func commonSuperview(_ a: NSView, _ b: NSView) -> NSView? {
        var ancestors = Set<ObjectIdentifier>()
        var node: NSView? = a
        while let current = node {
            ancestors.insert(ObjectIdentifier(current))
            node = current.superview
        }
        node = b
        while let current = node {
            if ancestors.contains(ObjectIdentifier(current)) { return current }
            node = current.superview
        }
        return nil
    }
}
