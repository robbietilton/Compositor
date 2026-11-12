import AppKit

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        let targetMask = activeLayer.flatMap { selectedMask(for: $0) }
        // A folder has no pixels of its own, so only its mask can be painted.
        return (tool != .brush || BrushLibrary.shared.brushes.first(where: { $0.id == selectedBrushPresetID })?.isRenderable != false)
            && canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || targetMask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
    }
    /// Why a stroke can't start on the target, for the alert, as Photoshop explains a brush it refuses. Nil when
    /// nothing about the target is in the way; while the editor is busy (a transform, a dialog) a press just waits.
    var paintRefusal: String? {
        guard canEditLayers, let layer = activeLayer, !canPaint else { return nil }
        if tool == .brush, BrushLibrary.shared.brushes.first(where: { $0.id == selectedBrushPresetID })?.isRenderable == false {
            return "This brush’s source is preserved, but its rendering settings have not been mapped yet. Choose a Compositor brush to paint."
        }
        if selectedLayerIDs.count > 1 { return "Several layers are selected. Select just one to paint on it." }
        if layer.isGroup, !isMaskSelected {
            return "“\(layer.name)” is a folder, which has no pixels of its own. Paint on a layer inside it, or on the folder’s mask."
        }
        if document?.effectiveVisibleIDs.contains(layer.id) != true {
            return "“\(layer.name)” is hidden, or inside a hidden folder. Show it to paint on it."
        }
        if isMaskSelected, selectedMask(for: layer)?.isEnabled != true {
            return "The layer mask is turned off. Shift-click its thumbnail to turn it on, then paint."
        }
        if !isMaskSelected, layer.adjustment != nil {
            return "“\(layer.name)” is an adjustment layer, with no pixels to paint. Paint on its mask instead."
        }
        if selection?.isEmpty == true {
            return "Nothing is selected, so there’s nowhere to paint. Choose Select › Deselect (⌘D) to paint anywhere."
        }
        return nil
    }
    /// Tiled raster edit of the active layer's pixels or mask, within the shared pixel budgets.
