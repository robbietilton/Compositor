import Foundation

/// Where a generated layer goes, and which layers it may be generated from. The model is sent the picture
/// as it looks from the new layer's place in the stack: whatever draws above that place — an adjustment
/// layer grading the whole document, say — will draw over the new layer too, and must not be baked into it.
nonisolated struct GenerativePlacement: Equatable, Sendable {
    /// Layers left out of the picture sent to the model: everything that draws above the new layer.
    let hiddenIDs: Set<UUID>
    /// Position in the document's flat layer list.
    let insertIndex: Int
    let parentID: UUID?

    static func plan(_ layers: [ProjectLayerRecord], activeID: UUID?) -> GenerativePlacement {
        // Drawing order walks folders depth-first; the flat list only orders siblings.
        let entries = LayerHierarchy.entries(layers)
        guard let activeID, let active = entries.firstIndex(where: { $0.layer.id == activeID }) else {
            return GenerativePlacement(hiddenIDs: [], insertIndex: layers.count, parentID: nil)
        }
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var anchor = entries[active].layer
        // A clipping stack is drawn as one unit and breaks apart if a layer lands inside it: go above it.
        let base = anchor.maskSourceID ?? anchor.id
        if let start = entries.firstIndex(where: { $0.layer.id == base }), start <= active {
            var end = start
            while end + 1 < entries.count, entries[end + 1].layer.maskSourceID == base,
                  entries[end + 1].layer.parentID == entries[start].layer.parentID { end += 1 }
            if active <= end { anchor = entries[end].layer }
        }
        // A folder that fades or masks its contents would fade or mask the new layer a second time, its
        // effect being in the sampled picture already: go above the outermost such folder.
        var parent = anchor.parentID, depth = 0
        while let id = parent, depth < 64, let folder = byID[id] {
            if (folder.opacity ?? 1) < 1 || (folder.maskFile != nil && folder.maskEnabled != false) { anchor = folder }
            parent = folder.parentID
            depth += 1
        }
        // A folder counts with everything inside it.
        var last = entries.firstIndex { $0.layer.id == anchor.id } ?? active
        if anchor.isGroup == true {
            let depth = entries[last].depth
            while last + 1 < entries.count, entries[last + 1].depth > depth { last += 1 }
        }
        let kept = Set(entries[...last].map(\.layer.id))
        // Folders stay: hiding one would hide the kept layers inside it.
        let hidden = Set(layers.filter { $0.isGroup != true && !kept.contains($0.id) }.map(\.id))
        let index = layers.firstIndex { $0.id == anchor.id }.map { $0 + 1 } ?? layers.count
        return GenerativePlacement(hiddenIDs: hidden, insertIndex: index, parentID: anchor.parentID)
    }
}
