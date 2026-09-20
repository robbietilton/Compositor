import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
final class ProjectTab: Identifiable {
    let id = UUID()
    let session: EditorSession
    let controller: ProjectController
    let defaultName: String
    var title: String { session.projectURL?.deletingPathExtension().lastPathComponent ?? defaultName }
    init(name: String) {
        defaultName = name
        session = EditorSession()
        controller = ProjectController(session: session)
    }
}

@MainActor @Observable
final class ProjectWorkspace {
    private(set) var tabs: [ProjectTab] = []
    private(set) var selectedID: UUID
    var isManaging = false
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var nextNumber = 2
    var current: ProjectTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var canSwitch: Bool {
        let s = current.session
        return !isManaging && s.canStartProjectOperation && s.hueSaturation == nil && s.filterEdit == nil
            && s.gradientEdit == nil && s.pixelMove == nil && s.colorPicker == nil
    }
    init() {
        let first = ProjectTab(name: "Untitled".localized)
        first.session.skipsInitialClipboardCanvasSize = true
        tabs = [first]; selectedID = first.id
        first.controller.workspace = self
    }
    @discardableResult
    func addTab(reuseEmpty: Bool = true) -> ProjectTab {
        if reuseEmpty, tabs.count == 1, current.session.document == nil { return current }
        let tab = ProjectTab(name: String(localized: "Untitled \(nextNumber)"))
        nextNumber += 1
        tab.controller.workspace = self; tab.controller.window = window
        tabs.append(tab); selectedID = tab.id
        return tab
    }
    func select(_ id: UUID) {
        guard id != selectedID, canSwitch, tabs.contains(where: { $0.id == id }) else { return }
        current.session.commitTransform()
        selectedID = id
        current.controller.window = window
    }
    func newCanvas() {
        guard canSwitch else { return }
        current.session.commitTransform()
        _ = addTab(reuseEmpty: false)
    }
    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        guard canSwitch else { return false }
        isManaging = true
        defer { isManaging = false }
        var urls = suppliedURL.map { [$0] } ?? []
        if urls.isEmpty {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = true
            panel.treatsFilePackagesAsDirectories = false
            let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            guard response == .OK else { return false }
            urls = panel.urls
        }
        var opened = false
        for url in urls { opened = await loadProject(url) || opened }
        return opened
    }
    private func loadProject(_ url: URL) async -> Bool {
        if let existing = tabs.first(where: { $0.session.projectURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
            selectedID = existing.id; return true
        }
        // Load into an unattached session, so a failed open never leaves a broken tab.
        let tab = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
        tab.controller.window = window
        guard await tab.controller.open(url) else { return false }
        if tabs.count == 1, current.session.document == nil { tabs.removeAll() }
        tab.controller.workspace = self; tabs.append(tab); selectedID = tab.id
        return true
    }
    func close(_ id: UUID) async {
        guard canSwitch, let tab = tabs.first(where: { $0.id == id }) else { return }
        isManaging = true
        defer { isManaging = false }
        tab.controller.window = window
        guard await tab.controller.confirmQuit() else { return }
        removeTab(id)
    }
    func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty { _ = addTab(reuseEmpty: false) }
        else if selectedID == id { selectedID = tabs[min(index, tabs.count-1)].id }
    }
    /// The order Quit (and closing the window) asks about unsaved projects: the tab on screen first,
    /// then the rest left to right, so it never jumps to another project before the one you're viewing.
    var quitOrder: [ProjectTab] { [current] + tabs.filter { $0.id != current.id } }
    func confirmQuit() async -> Bool {
        guard canSwitch else { return false }
        isManaging = true; defer { isManaging = false }
        for tab in quitOrder {
            selectedID = tab.id; tab.controller.window = window
            guard await tab.controller.confirmQuit() else { return false }
        }
        return true
    }
    func closeWindow(_ window: NSWindow) async {
        guard await confirmQuit() else { return }
        tabs.removeAll(); _ = addTab(reuseEmpty: false)
        window.close()
    }

    /// Capture the destination before asynchronous provider loading. Dock/new-tab
    /// drops create one project per image; existing-tab drops add image layers.
    func receive(_ urls: [URL], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (url, scoped) in files where scoped { url.stopAccessingSecurityScopedResource() } }
        while !canSwitch {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        isManaging = true; defer { isManaging = false }
        for url in urls {
            if url.pathExtension.lowercased() == "comp" { _ = await loadProject(url); continue }
            let tab: ProjectTab
            if let destination {
                guard let existing = tabs.first(where: { $0.id == destination }) else { continue }
                tab = existing
            } else { tab = addTab() }
            selectedID = tab.id
            await tab.session.importImages([url], at: point)
        }
    }
    func receiveProviders(_ providers: [NSItemProvider], into destination: UUID? = nil, at point: CGPoint? = nil) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(Self.layerType) {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: Self.layerType) { data, _ in continuation.resume(returning: data) }
                }
                if let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    await copyLayer(id, into: destination, at: point)
                }
            } else {
                await ImageFileDrop.importProviders([provider], into: current.session, at: point, workspace: self, destination: destination)
            }
        }
    }
    static let layerType = "com.compositor.layer-row"
    func copyLayer(_ id: UUID, into destination: UUID?, at point: CGPoint? = nil) async {
        guard canSwitch, let sourceTab = tabs.first(where: { $0.session.document?.layers.contains(where: { $0.id == id }) == true }),
              sourceTab.session.canEditLayers, let snapshot = sourceTab.session.projectSnapshot(),
              let sourceDocument = sourceTab.session.document else { return }
        if let destination, destination == sourceTab.id { return }
        let target: ProjectTab
        if let destination {
            guard let existing = tabs.first(where: { $0.id == destination }), existing.session.canStartProjectOperation else { return }
            target = existing
        } else { target = addTab(reuseEmpty: false) }
        guard target.session.document == nil || target.session.canEditLayers else { return }
        let included = sourceTab.session.descendantIDs(of: id).union([id])
        var copied = sourceDocument.layers.filter { included.contains($0.id) }
        let used = target.session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        let added = copied.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) }
        guard used + added <= 100_000_000 else { target.session.importError = "The copied layers exceed this project’s 100-megapixel limit.".localized; return }
        isManaging = true
        sourceTab.session.isProjectBusy = true
        target.session.isProjectBusy = true
        defer {
            isManaging = false
            sourceTab.session.isProjectBusy = false
            target.session.isProjectBusy = false
        }
        do {
            for i in copied.indices where copied[i].maskSourceID.map({ !included.contains($0) }) == true {
                if copied[i].adjustment != nil { copied[i].maskSourceID = nil; continue }
                let layerID = copied[i].id
                copied[i].asset = try await Task.detached(priority: .userInitiated) { try LiveMaskBaker.bake(snapshot, target: layerID) }.value
                copied[i].maskSourceID = nil
            }
            let mapping = Dictionary(uniqueKeysWithValues: copied.map { ($0.id, UUID()) })
            let size = target.session.document?.size ?? sourceDocument.size
            let anchor = copied.first(where: { $0.id == id })?.transform.center ?? CGPoint(x: sourceDocument.size.width/2, y: sourceDocument.size.height/2)
            let center = point ?? CGPoint(x: size.width/2, y: size.height/2)
            let layers = copied.map { layer -> ImageLayer in
                var transform = layer.transform
                transform.origin.x += center.x-anchor.x; transform.origin.y += center.y-anchor.y
                var mask = layer.mask
                mask?.placement?.origin.x += center.x-anchor.x; mask?.placement?.origin.y += center.y-anchor.y
                return ImageLayer(id: mapping[layer.id]!, asset: layer.asset, name: layer.name, isVisible: layer.isVisible,
                    transform: transform, parentID: layer.parentID.flatMap { mapping[$0] }, isGroup: layer.isGroup,
                    opacity: layer.opacity, blendMode: layer.blendMode, mask: mask, maskSourceID: layer.maskSourceID.flatMap { mapping[$0] }, adjustment: layer.adjustment, shape: layer.shape, text: layer.text)
            }
            target.session.isProjectBusy = false
            target.session.beginEdit("Copy Layers from Project")
            if target.session.document == nil { target.session.createDocument(width: Int(size.width), height: Int(size.height)) }
            target.session.document?.layers.append(contentsOf: layers)
            target.session.activeLayerID = mapping[id]
            target.session.endEdit()
            selectedID = target.id
        } catch { target.session.importError = error.localizedDescription }
    }
}
