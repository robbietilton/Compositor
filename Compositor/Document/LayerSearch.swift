import Foundation

/// The Layers panel's type filter: the kinds of layer the list narrows to while their toggles are on, and Selected,
/// the layers selected right now.
enum LayerType: String, CaseIterable {
    case image, shape, text, folder, adjustment, selected
}

extension ImageLayer {
    /// Which of the panel's type filters the layer belongs to. Text means editable text; rasterized
    /// text counts as an image, as it does everywhere else in the app.
    var layerType: LayerType {
        if isGroup { return .folder }
        if adjustment != nil { return .adjustment }
        if liveText != nil { return .text }
        if shape != nil { return .shape }
        return .image
    }
}

extension EditorSession {
    /// Whether the panel's search text or type filter is on.
    var isFilteringLayers: Bool { !layerSearchText.isEmpty || !layerTypeFilter.isEmpty }
    /// The rows the panel shows: `layerRows` narrowed by the search text and type filter. While a filter
    /// is on, folders list themselves opened, so layers inside collapsed folders can be found too.
    var filteredLayerRows: [LayerHierarchy.Entry] {
        let entries = LayerHierarchy.entries(document?.layers.map(\.hierarchyRecord) ?? [], topFirst: true,
                                             collapsed: isFilteringLayers ? [] : collapsedGroupIDs)
        guard isFilteringLayers else { return entries }
        let query = layerSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        let byID = Dictionary(uniqueKeysWithValues: (document?.layers ?? []).map { ($0.id, $0) })
        func matches(_ layer: ImageLayer) -> Bool {
            (query.isEmpty || layer.name.lowercased().contains(query))
                && (layerTypeFilter.isEmpty || layerTypeFilter.contains(layer.layerType)
                    || (layerTypeFilter.contains(.selected) && selectedLayerIDs.contains(layer.id)))
        }
        // A folder that matches brings everything inside it along, so its contents can be seen and worked on.
        let matched = Set((document?.layers ?? []).filter(matches).map(\.id))
        func insideMatchedFolder(_ layer: ImageLayer) -> Bool {
            var parent = layer.parentID
            while let id = parent {
                if matched.contains(id) { return true }
                parent = byID[id]?.parentID
            }
            return false
        }
        return entries.filter { entry in
            guard let layer = byID[entry.layer.id] else { return false }
            return matched.contains(layer.id) || insideMatchedFolder(layer)
        }
    }
    /// Clears the panel's search text.
    func clearLayerSearch() {
        layerSearchText = ""
    }
    /// Clears the panel's every type toggle.
    func clearLayerTypeFilter() {
        layerTypeFilter = []
    }
}
