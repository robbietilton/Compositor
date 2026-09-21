import AppKit

extension EditorSession {
    /// Uses the ordinary color editors, but sends their changes to layer metadata.
    /// The source is only for the histogram and sampling; it never replaces layer pixels.
    func beginAdjustmentEditing(_ id: UUID) async {
        guard adjustmentEditingID == id, adjustmentOriginal == nil,
              levels == nil, hueSaturation == nil, filterEdit == nil,
              let snapshot = projectSnapshot(),
              let index = snapshot.manifest.layers.firstIndex(where: { $0.id == id }),
              let original = snapshot.manifest.layers[index].adjustment else { return }
        var manifest = snapshot.manifest
        // Keep records for live-mask references and group ancestry, but exclude the
        // adjustment itself and everything above it from the sampling image.
        let underneath = Set(LayerHierarchy.entries(manifest.layers).prefix { $0.layer.id != id }.map { $0.layer.id })
        for i in manifest.layers.indices where manifest.layers[i].isGroup != true && !underneath.contains(manifest.layers[i].id) {
            manifest.layers[i].isVisible = false
        }
        let source = ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
        do {
            let raster = try await ImageExporter.shared.render(source)
            guard !Task.isCancelled, adjustmentEditingID == id, adjustmentOriginal == nil else { return }
            let asset = ImportedImage(image: raster.image, thumbnail: try PixelAdjust.thumbnail(of: raster.image), name: "Adjustment input")
            let layer = ImageLayer(asset: asset, origin: .zero)
            switch original.kind {
            case .levels:
                let edit = try LevelsEdit(layer: layer, selection: nil)
                edit.settings = original.levels
                levels = edit
                let job = edit.previewJob
                edit.histogramTask = Task { @MainActor [weak self, weak edit] in
                    let bins = await Task.detached(priority: .userInitiated) { try? LevelsFilter.histogram(job) }.value
                    guard let self, let edit, self.levels === edit, !Task.isCancelled else { return }
                    if let bins { edit.histogram = bins }
                    edit.histogramReady = true
                }
            case .hsv:
                let edit = try HueSaturationEdit(layerID: layer.id, original: asset, selection: nil, transform: layer.transform)
                edit.settings = original.resolvedHSV
                hueSaturation = edit
            case .curves, .exposure, .gradientMap, .grain:
                var settings = FilterSettings()
                settings.curves = original.curves
                settings.exposure = original.exposure
                settings.gradientMap = original.gradientMap
                settings.grain = original.grain
                filterEdit = try FilterEdit(kind: original.kind.filterKind ?? .curves, layer: layer, selection: nil, settings: settings)
            }
            adjustmentOriginal = original
            beginEdit(String(format: String(localized: "Edit %@ Adjustment"), String(localized: String.LocalizationValue(original.kind.rawValue))))
        } catch {
            guard adjustmentEditingID == id else { return }
            adjustmentEditingID = nil
            brushError = error.localizedDescription
        }
    }

    private var editedAdjustment: LayerAdjustment? {
        guard var value = adjustmentOriginal else { return nil }
        switch value.kind {
        case .levels:
            guard let levels else { return nil }
            value.levels = levels.settings
        case .hsv:
            guard let hueSaturation else { return nil }
            value.hsvSettings = hueSaturation.settings
        case .curves, .exposure, .gradientMap, .grain:
            guard let filterEdit else { return nil }
            switch value.kind {
            case .exposure: value.exposure = filterEdit.settings.exposure
            case .gradientMap: value.gradientMap = filterEdit.settings.gradientMap
            case .grain: value.grain = filterEdit.settings.grain
            default: value.curves = filterEdit.settings.curves
            }
        }
        return value
    }

    @discardableResult
    func previewAdjustmentEditing(preview: Bool) -> Bool {
        guard let id = adjustmentEditingID, let original = adjustmentOriginal,
              let value = editedAdjustment else { return false }
        updateAdjustment(id, value: preview ? value : original)
        return true
    }

    /// OK keeps editable settings; Cancel (including the window close button) restores them.
    @discardableResult
    func finishAdjustmentEditing(commit: Bool) -> Bool {
        guard let id = adjustmentEditingID, let original = adjustmentOriginal else { return false }
        updateAdjustment(id, value: commit ? (editedAdjustment ?? original) : original)
        levels?.previewTask?.cancel()
        levels?.histogramTask?.cancel()
        filterEdit?.previewTask?.cancel()
        hueSaturationTask?.cancel()
        hueSaturationPending = nil
        hueSampleMode = nil
        hueTargeting = false
        hueTargetDrag = nil
        levels = nil
        hueSaturation = nil
        filterEdit = nil
        endEdit()
        adjustmentOriginal = nil
        adjustmentEditingID = nil
        canvasFocusRequest += 1
        brushRevision += 1
        return true
    }
}
