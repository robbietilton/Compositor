import Foundation

nonisolated enum LayerHierarchy {
    struct Entry {
        let layer: ProjectLayerRecord
        let depth: Int
        let visible: Bool
    }
    static func entries(_ layers: [ProjectLayerRecord], topFirst: Bool = false,
                        collapsed: Set<UUID> = []) -> [Entry] {
        let children = Dictionary(grouping: layers, by: \.parentID)
        var result: [Entry] = []
        func visit(_ parent: UUID?, depth: Int, visible: Bool) {
            guard depth <= 64 else { return }
            let siblings = children[parent] ?? []
            for layer in topFirst ? Array(siblings.reversed()) : siblings {
                let effective = visible && layer.isVisible
                result.append(Entry(layer: layer, depth: depth, visible: effective))
                if layer.isGroup == true, !collapsed.contains(layer.id) {
                    visit(layer.id, depth: depth + 1, visible: effective)
                }
            }
        }
        visit(nil, depth: 0, visible: true)
        return result
    }
    static func visibleLayers(_ layers: [ProjectLayerRecord]) -> [ProjectLayerRecord] {
        entries(layers).filter { $0.visible && $0.layer.isGroup != true }.map(\.layer)
    }
    static func validate(_ layers: [ProjectLayerRecord]) throws {
        var byID: [UUID: ProjectLayerRecord] = [:]
        for layer in layers {
            guard byID.updateValue(layer, forKey: layer.id) == nil,
                  layer.isGroup != true || layer.imageFile == nil else { throw ProjectError.invalid }
        }
        for layer in layers {
            var seen: Set<UUID> = [layer.id]
            var parent = layer.parentID
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted,
                      let node = byID[id], node.isGroup == true else { throw ProjectError.invalid }
                parent = node.parentID
            }
            if layer.isGroup == true, seen.count > 64 { throw ProjectError.invalid }
        }
    }
}

/// A folder's opacity multiplies into everything inside it: a layer at 50% in a folder at 50%
/// shows at 25%, while the layer itself still reads 50% in the panel. Folders are pass-through —
/// what's inside is drawn straight onto what is below, never composited as a unit — so the
/// folder's opacity is applied to each of those layers rather than to the folder as a whole.
nonisolated enum LayerOpacity {
    static func effective(_ own: Double, parent: UUID?,
                          folder: (UUID) -> (opacity: Double, parentID: UUID?)?) -> Double {
        var opacity = own, id = parent, depth = 0
        while let current = id, depth < 64, let node = folder(current) {
            opacity *= node.opacity
            id = node.parentID
            depth += 1
        }
        return opacity
    }
}

extension ImageLayer {
    /// The opacity this layer is drawn at, folders included (see LayerOpacity).
    func effectiveOpacity(in byID: [UUID: ImageLayer]) -> Double {
        LayerOpacity.effective(opacity, parent: parentID) { byID[$0].map { ($0.opacity, $0.parentID) } }
    }
    var hierarchyRecord: ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: transform,
            imageFile: asset == nil ? nil : "\(id.uuidString).png", parentID: parentID, isGroup: isGroup, opacity: opacity, blendMode: blendMode, maskFile: mask == nil ? nil : "\(id.uuidString).mask.png", maskEnabled: mask?.isEnabled, maskSourceID: maskSourceID, adjustment: adjustment, maskPlacement: mask?.placement, maskLinked: mask?.isLinked)
    }
}
nonisolated extension ProjectLayerRecord {
    /// The opacity this layer is drawn at, folders included (see LayerOpacity).
    func effectiveOpacity(in byID: [UUID: ProjectLayerRecord]) -> Double {
        LayerOpacity.effective(opacity ?? 1, parent: parentID) { byID[$0].map { ($0.opacity ?? 1, $0.parentID) } }
    }
}
extension CanvasDocument {
    var effectiveOpacities: [UUID: Double] {
        let folders = Dictionary(uniqueKeysWithValues: layers.lazy.map { ($0.id, (opacity: $0.opacity, parentID: $0.parentID)) })
        return folders.mapValues { LayerOpacity.effective($0.opacity, parent: $0.parentID) { folders[$0] } }
    }
    /// Every layer and folder in drawing order (each folder before what's inside it), and which of them show.
    var hierarchy: LayerOrder.Result { LayerOrder.resolve(layers) }
    var effectiveVisibleIDs: Set<UUID> { hierarchy.visible }
    var renderLayers: [ImageLayer] {
        let order = hierarchy.drawn
        guard !order.isEmpty else { return [] }
        let index = Dictionary(uniqueKeysWithValues: layers.indices.lazy.map { (layers[$0].id, $0) })
        return order.compactMap { index[$0].map { layers[$0] } }
    }
}

/// The layer hierarchy worked out from only what shapes it — each layer's id, folder, and visibility — and kept until
/// one of those changes. The canvas asks for it several times on every event; rebuilt each time from whole layer
/// records, a document of hundreds of layers spent most of its time on it.
nonisolated enum LayerOrder {
    struct Node: Equatable {
        let id: UUID
        let parentID: UUID?
        let isGroup: Bool
        let isVisible: Bool
    }
    struct Result {
        /// Every layer and folder, in the order `LayerHierarchy.entries` lists them.
        let order: [UUID]
        /// The ones that show: visible, in folders that are.
        let visible: Set<UUID>
        /// The layers that show, folders left out, bottom to top.
        let drawn: [UUID]
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (nodes: [Node], result: Result)?

    static func resolve(_ layers: [ImageLayer]) -> Result {
        let nodes = layers.map { Node(id: $0.id, parentID: $0.parentID, isGroup: $0.isGroup, isVisible: $0.isVisible) }
        if let known = lock.withLock({ last }), known.nodes == nodes { return known.result }
        let children = Dictionary(grouping: nodes, by: \.parentID)
        var order: [UUID] = [], visible = Set<UUID>(), drawn: [UUID] = []
        func visit(_ parent: UUID?, depth: Int, shown: Bool) {
            guard depth <= 64 else { return }
            for node in children[parent] ?? [] {
                let effective = shown && node.isVisible
                order.append(node.id)
                if effective {
                    visible.insert(node.id)
                    if !node.isGroup { drawn.append(node.id) }
                }
                if node.isGroup { visit(node.id, depth: depth + 1, shown: effective) }
            }
        }
        visit(nil, depth: 0, shown: true)
        let result = Result(order: order, visible: visible, drawn: drawn)
        lock.withLock { last = (nodes, result) }
        return result
    }
}

extension EditorSession {
    func selectLayers(_ ids: Set<UUID>, primary: UUID?) {
        effectSelection = nil
        if ids != selectedLayerIDs, !finishText() { return }
        guard brushStroke == nil else { return }
        let valid = ids.intersection(Set(document?.layers.map(\.id) ?? []))
        if valid != selectedLayerIDs { commitTransform(); resolveGradient() }
        activeLayerID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.first
        selectedLayerIDs = valid
    }

    /// Cmd-Shift-click on the canvas: adds a layer to the selection, or takes it out again when it is already in it.
    func extendSelection(with id: UUID) {
        guard canEditLayers || transformEdit != nil, document?.layers.contains(where: { $0.id == id }) == true else { return }
        var ids = selectedLayerIDs
        if ids.contains(id), ids.count > 1 {
            ids.remove(id)
            selectLayers(ids, primary: activeLayerID == id ? ids.first : activeLayerID)
        } else {
            ids.insert(id)
            selectLayers(ids, primary: id)
        }
    }

    func groupSelectedLayers() {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let selected = selectedLayerIDs.intersection(Set(byID.keys))
        func ancestors(_ id: UUID) -> [UUID?] {
            var result: [UUID?] = []
            var parent = byID[id]?.parentID
            while let id = parent { result.append(id); parent = byID[id]?.parentID }
            result.append(nil)
            return result
        }
        // A selected folder carries its subtree; selected descendants must not be pulled out of it.
        let rootIDs = selected.filter { id in !ancestors(id).contains { $0.map(selected.contains) ?? false } }
        let ordered = document.hierarchy.order.filter(rootIDs.contains)
        let parent: UUID? = ordered.first.flatMap { first in
            ancestors(first).first { candidate in ordered.allSatisfy { ancestors($0).contains(candidate) } } ?? nil
        }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: document.size)
        group.isGroup = true
        group.parentID = parent
        // Put the wrapper at the topmost selected branch in the common parent.
        let branches = ordered.map { id -> UUID in
            var branch = id
            while let next = byID[branch]?.parentID, next != parent { branch = next }
            return branch
        }
        let highest = document.layers.lastIndex { branches.contains($0.id) }
        let insertion = highest.map { document.layers.prefix($0 + 1).filter { !rootIDs.contains($0.id) }.count }
            ?? document.layers.count
        var layers = document.layers.filter { !rootIDs.contains($0.id) }
        layers.insert(group, at: min(insertion, layers.count))
        for id in ordered {
            guard var child = byID[id] else { continue }
            child.parentID = group.id
            layers.append(child)
        }
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("Group Layers")
        self.document?.layers = layers
        activeLayerID = group.id
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
    }

    /// The active layer must be a folder, so there is something to unwrap.
    var canUngroupLayers: Bool { canEditLayers && activeLayer?.isGroup == true }

    /// Reverses Group from Layers: the folder's direct children take its place among its own siblings, in the
    /// order they had inside it, and the folder goes. Its own opacity, blend mode, mask and effects are
    /// discarded along with it, as Photoshop's Ungroup does.
    func ungroupLayers() {
        guard canUngroupLayers, let group = activeLayer, let document else { return }
        let childIDs = Set(document.layers.filter { $0.parentID == group.id }.map(\.id))
        var children = document.layers.filter { childIDs.contains($0.id) }
        for i in children.indices { children[i].parentID = group.parentID }
        // Spliced in at the folder's own spot, so they land exactly where it sat among its siblings.
        var layers: [ImageLayer] = []
        for layer in document.layers {
            if layer.id == group.id { layers.append(contentsOf: children) }
            else if !childIDs.contains(layer.id) { layers.append(layer) }
        }
        Self.releaseDetachedClipping(in: &layers)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        finishOpacityEdit()
        beginEdit("Ungroup Layers")
        self.document?.layers = layers
        selectLayers(childIDs, primary: children.first?.id)
        collapsedGroupIDs.remove(group.id)
        endEdit()
    }

    var layerRows: [LayerHierarchy.Entry] {
        LayerHierarchy.entries(document?.layers.map(\.hierarchyRecord) ?? [], topFirst: true, collapsed: collapsedGroupIDs)
    }
    func descendantIDs(of id: UUID) -> Set<UUID> {
        let children = Dictionary(grouping: document?.layers ?? [], by: \.parentID)
        var result = Set<UUID>(), pending = [id]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }
    func addGroup() {
        guard canEditLayers, let document, document.layers.count < 10_000 else { return }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        var group = ImageLayer(name: "Folder \(number)", blankSize: document.size)
        group.isGroup = true
        group.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        var layers = document.layers
        let insertion = layers.firstIndex(where: { $0.id == activeLayerID }).map { $0 + 1 } ?? layers.count
        layers.insert(group, at: insertion)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
        beginEdit("New Folder")
        self.document?.layers = layers
        activeLayerID = group.id
        if let parent = group.parentID { collapsedGroupIDs.remove(parent) }
        endEdit()
    }
    func toggleGroupExpansion(_ id: UUID) {
        guard !isProjectBusy, document?.layers.first(where: { $0.id == id })?.isGroup == true else { return }
        if collapsedGroupIDs.contains(id) { collapsedGroupIDs.remove(id) }
        else {
            if activeLayerID.map({ descendantIDs(of: id).contains($0) }) == true { selectLayer(id) }
            collapsedGroupIDs.insert(id)
        }
    }
    func canPlaceLayer(_ id: UUID, in parent: UUID?) -> Bool {
        guard canEditLayers, document?.layers.contains(where: { $0.id == id }) == true else { return false }
        guard let parent else { return true }
        return parent != id && !descendantIDs(of: id).contains(parent)
            && document?.layers.first(where: { $0.id == parent })?.isGroup == true
    }
    @discardableResult
    func placeLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canPlaceLayer(id, in: parent), var layers = document?.layers,
              let index = layers.firstIndex(where: { $0.id == id }), target != id else { return false }
        var layer = layers.remove(at: index)
        layer.parentID = parent
        var insertion = atBottom ? 0 : layers.count
        if let target {
            guard let targetIndex = layers.firstIndex(where: { $0.id == target && $0.parentID == parent }) else { return false }
            insertion = targetIndex + 1
        }
        layers.insert(layer, at: insertion)
        Self.adoptClipping(id, in: &layers)
        Self.releaseDetachedClipping(in: &layers)
        guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return false }
        beginEdit("Move Layer")
        document?.layers = layers
        activeLayerID = id
        if let parent { collapsedGroupIDs.remove(parent) }
        endEdit()
        return true
    }
    func moveActiveLayerOutOfGroup() {
        guard let layer = activeLayer, let parent = layer.parentID,
              let group = document?.layers.first(where: { $0.id == parent }) else { return }
        placeLayer(layer.id, in: group.parentID, above: group.id)
    }
}
