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

extension ImageLayer {
    var hierarchyRecord: ProjectLayerRecord {
        ProjectLayerRecord(id: id, name: name, isVisible: isVisible, transform: transform,
            imageFile: asset == nil ? nil : "\(id.uuidString).png", parentID: parentID, isGroup: isGroup, opacity: opacity, blendMode: blendMode, maskFile: mask == nil ? nil : "\(id.uuidString).mask.png", maskEnabled: mask?.isEnabled, maskSourceID: maskSourceID, adjustment: adjustment, maskPlacement: mask?.placement, maskLinked: mask?.isLinked)
    }
}
extension CanvasDocument {
    var hierarchyEntries: [LayerHierarchy.Entry] { LayerHierarchy.entries(layers.map(\.hierarchyRecord)) }
    var effectiveVisibleIDs: Set<UUID> { Set(hierarchyEntries.filter(\.visible).map { $0.layer.id }) }
    var renderLayers: [ImageLayer] {
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        return hierarchyEntries.filter { $0.visible && $0.layer.isGroup != true }.compactMap { byID[$0.layer.id] }
    }
}

extension EditorSession {
    func selectLayers(_ ids: Set<UUID>, primary: UUID?) {
        guard brushStroke == nil else { return }
        let valid = ids.intersection(Set(document?.layers.map(\.id) ?? []))
        if valid != selectedLayerIDs { commitTransform(); resolveGradient() }
        activeLayerID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.first
        selectedLayerIDs = valid
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
        let ordered = document.hierarchyEntries.map { $0.layer.id }.filter(rootIDs.contains)
        let parent: UUID? = ordered.first.flatMap { first in
            ancestors(first).first { candidate in ordered.allSatisfy { ancestors($0).contains(candidate) } } ?? nil
        }
        let names = Set(document.layers.map(\.name))
        var number = 1
        while names.contains(String(localized: "Folder \(number)")) { number += 1 }
        var group = ImageLayer(name: String(localized: "Folder \(number)"), blankSize: document.size)
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
        while names.contains(String(localized: "Folder \(number)")) { number += 1 }
        var group = ImageLayer(name: String(localized: "Folder \(number)"), blankSize: document.size)
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
