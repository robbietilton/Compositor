import AppKit

/// What Render Finish processes: the active image layer, or everything visible merged into one image.
nonisolated enum FinishSource: String, CaseIterable, Identifiable, Sendable {
    case layer = "Layer", mergedVisible = "Merged Visible"
    var id: Self { self }
}

nonisolated enum RenderFinishError: LocalizedError {
    case documentChanged
    var errorDescription: String? { "The document changed while Darkroom was open, so nothing was applied." }
}

/// Zoomed in past the preview's own resolution, the part of the layer on screen is rendered again at full size,
/// so fine texture can be judged before applying.
nonisolated struct FinishDetail: @unchecked Sendable {
    struct Request: Equatable {
        /// The part of the layer (in its pixels) this detail shows as the whole layer's result would.
        let valid: CGRect
        let settings: FilterSettings
    }
    let request: Request
    let image: CGImage
    /// Where the processed crop, `valid` plus room for the blurs, sits on the document.
    let transform: LayerTransform
}

extension FilterEdit {
    var finishSource: FinishSource { mergedLayers == nil ? .layer : .mergedVisible }
}

nonisolated extension LayerEffects {
    /// The same effects for the layer's pixels resampled by `factor` (a downscaled preview, an upscaled layer): effect
    /// sizes are in layer pixels. Kept within the ranges the effects accept.
    func scaled(by factor: CGFloat) -> LayerEffects {
        var result = self
        result.stroke?.size = min(StrokeEffect.maxSize, (stroke?.size ?? 0) * factor)
        result.shadow?.distance = min(5000, (shadow?.distance ?? 0) * factor)
        result.shadow?.blur = min(500, (shadow?.blur ?? 0) * factor)
        result.innerShadow?.distance = min(5000, (innerShadow?.distance ?? 0) * factor)
        result.innerShadow?.blur = min(500, (innerShadow?.blur ?? 0) * factor)
        result.outerGlow?.size = min(500, (outerGlow?.size ?? 0) * factor)
        return result
    }
}

nonisolated extension PixelFilter {
    /// Where `crop` (in the pixels of an image `width` × `height`, placed by `placed`) sits on the document, placed as
    /// `trimmed` places its crop.
    static func placement(of crop: CGRect, in placed: LayerTransform, width: Int, height: Int) -> LayerTransform {
        var result = placed
        result.size = CGSize(width: crop.width * placed.size.width / CGFloat(width),
                             height: crop.height * placed.size.height / CGFloat(height))
        let middle = CGPoint(x: crop.midX, y: crop.midY).applying(BrushRaster.pixelToDocument(placed, width: width, height: height))
        result.origin = CGPoint(x: middle.x - result.size.width / 2, y: middle.y - result.size.height / 2)
        return result
    }
}

extension EditorSession {
    /// The largest crop, blur room included, rendered for the zoomed-in preview: a 4K screen with room to spare.
    static let finishDetailLimit: CGFloat = 16_000_000

    var canFinishMergedVisible: Bool {
        _ = showsBusy
        guard let document, filterEdit == nil, levels == nil, hueSaturation == nil, !isProjectBusy, !isImporting,
              brushStroke == nil, warpStroke == nil, pixelMove == nil, textDraft == nil, renamingLayerID == nil,
              selectionAmountOperation == nil, adjustmentEditingID == nil, !showsNewDocument, !showsImporter, !showsConversionSheet,
              selection?.isEmpty != true, document.layers.count < 10_000 else { return false }
        return !document.renderLayers.isEmpty
    }

    func beginRenderFinish(source: FinishSource) {
        guard source == .mergedVisible else { beginFilter(.renderFinish); return }
        guard canFinishMergedVisible else { NSSound.beep(); return }
        if gradientEdit != nil {
            Task { await commitGradient(); beginRenderFinish(source: source) }
            return
        }
        commitTransform(); cancelCrop(); cancelLasso()
        do {
            guard let edit = try makeFinishEdit(source, settings: filterSettings) else { NSSound.beep(); return }
            filterEdit = edit
            updateFilter(edit.settings, preview: true)
        } catch { brushError = error.localizedDescription }
    }

    /// Switches an open Render Finish between the active layer and the merged canvas, keeping its settings and view.
    func setFinishSource(_ source: FinishSource) {
        guard let edit = filterEdit, edit.kind == .renderFinish, !edit.committing, edit.finishSource != source else { return }
        // Checked as if Render Finish were closed, so the same rules apply as when it opens.
        filterEdit = nil
        let next: FilterEdit?
        do { next = try makeFinishEdit(source, settings: edit.settings) }
        catch { brushError = error.localizedDescription; next = nil }
        guard let next else { filterEdit = edit; NSSound.beep(); return }
        edit.previewTask?.cancel()
        edit.finishDetailTask?.cancel()
        next.comparisonMode = edit.comparisonMode
        next.splitPosition = edit.splitPosition
        next.comparisonFill = edit.comparisonFill
        filterEdit = next
        updateFilter(next.settings, preview: edit.preview)
    }

    private func makeFinishEdit(_ source: FinishSource, settings: FilterSettings) throws -> FilterEdit? {
        guard let document else { return nil }
        let selection = try selection?.clip(canvas: document.size)
        guard source == .mergedVisible else {
            guard canAdjustColors, let layer = activeLayer else { return nil }
            return try FilterEdit(kind: .renderFinish, layer: layer, selection: selection, settings: settings)
        }
        guard canFinishMergedVisible else { return nil }
        // The canvas as it shows now, standing in for a layer that covers the whole document.
        let context = try BrushRaster.context(width: document.width, height: document.height, mask: false)
        drawLiveComposite(document, in: context)
        guard let composite = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: composite, thumbnail: try PixelAdjust.thumbnail(of: composite),
                                  name: FinishSource.mergedVisible.rawValue)
        let canvas = ImageLayer(id: UUID(), asset: asset, name: FinishSource.mergedVisible.rawValue, isVisible: true,
                                transform: LayerTransform(origin: .zero, size: document.size))
        let edit = try FilterEdit(kind: .renderFinish, layer: canvas, selection: selection, settings: settings)
        edit.mergedLayers = document.layers
        return edit
    }

    /// Darkroom's Apply, from its button and the canvas's Return key alike.
    func applyDarkroom() async {
        let factor = filterEdit?.enlargeFactor ?? 0
        await commitFilter()
        // Enlarger, when it is the last step, runs on the finished document with its own progress and undo step.
        if factor > 1, filterEdit == nil, brushError == nil { Self.enlargeAfterDarkroom?(self, factor) }
    }

    /// Apply Finish: the result goes on a new layer and source visibility changes as one undo step. A layer's
    /// result sits just above it; the merged canvas's goes on top and hides the original top-level layers/groups.
    func insertRenderFinish(_ edit: FilterEdit, asset: ImportedImage, transform: LayerTransform) throws {
        guard var layers = document?.layers else { return }
        let active = edit.settings.renderFinish.activeEffects
        let suffix = active.count == 1 ? active[0].title : FilterKind.renderFinish.rawValue
        let result: ImageLayer
        if let merged = edit.mergedLayers {
            guard layers == merged else { throw RenderFinishError.documentChanged }
            result = ImageLayer(id: UUID(), asset: asset, name: "\(FinishSource.mergedVisible.rawValue) · \(suffix)",
                                isVisible: true, transform: transform)
            // The composite already contains their opacity, masks, effects and blending. Leaving them
            // visible underneath would composite translucent pixels twice and disagree with the preview.
            for i in layers.indices where layers[i].parentID == nil { layers[i].isVisible = false }
            layers.append(result)
        } else {
            guard let index = layers.firstIndex(where: { $0.id == edit.layerID }),
                  layers[index].asset?.image === edit.original.image,
                  layers[index].transform == edit.transform else { throw RenderFinishError.documentChanged }
            let current = layers[index]
            result = ImageLayer(id: UUID(), asset: asset, name: "\(current.name) · \(suffix)",
                isVisible: current.isVisible, transform: current.transform, parentID: current.parentID,
                opacity: current.opacity, blendMode: current.blendMode, mask: current.mask,
                maskSourceID: current.maskSourceID, effects: current.effects)
            // Keep the source as a hidden backup so translucent pixels, masks and shadows
            // are not composited twice. Existing clipped layers follow the visible result.
            layers[index].isVisible = false
            for i in layers.indices where layers[i].maskSourceID == current.id { layers[i].maskSourceID = result.id }
            layers.insert(result, at: index + 1)
        }
        try LayerHierarchy.validate(layers.map(\.hierarchyRecord))
        beginEdit(FilterKind.renderFinish.rawValue)
        document?.layers = layers
        activeLayerID = result.id
        endEdit()
    }

    /// Called as the canvas draws: `visible` is the part of the layer on screen, in its own pixels, or nil when the
    /// preview is sharp enough. Renders it at full size shortly after the view and settings stop changing.
    func requestFinishDetail(_ visible: CGRect?, redraw: @escaping @MainActor () -> Void) {
        guard let edit = filterEdit, edit.kind == .renderFinish, !edit.committing else { return }
        guard let visible, !visible.isEmpty, !edit.settings.renderFinish.isIdentity else {
            edit.finishDetailTask?.cancel()
            edit.finishDetailTask = nil
            edit.finishDetailPending = nil
            return
        }
        let settings = edit.settings
        if let detail = edit.finishDetail, detail.request.settings == settings, detail.request.valid.contains(visible) { return }
        if let pending = edit.finishDetailPending, pending.settings == settings, pending.valid.contains(visible) { return }
        edit.finishDetailTask?.cancel()
        let source = edit.original.image
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let reach = CGFloat(settings.renderFinish.reach())
        // A little more than is visible, so a small pan can reuse it.
        var valid = visible.insetBy(dx: -visible.width * 0.1, dy: -visible.height * 0.1).intersection(bounds).integral
        var rect = valid.insetBy(dx: -reach, dy: -reach).intersection(bounds).integral
        if rect.width * rect.height > Self.finishDetailLimit {
            valid = visible
            rect = valid.insetBy(dx: -reach, dy: -reach).intersection(bounds).integral
        }
        guard rect.width * rect.height <= Self.finishDetailLimit else { edit.finishDetailPending = nil; return }
        let request = FinishDetail.Request(valid: valid, settings: settings)
        edit.finishDetailPending = request
        let selection = edit.selection, seed = edit.seed
        let mapping = CGAffineTransform(translationX: rect.minX, y: rect.minY).concatenating(edit.mapping)
        let region = FinishRegion(x: Int(rect.minX), y: Int(rect.minY), fullWidth: source.width, fullHeight: source.height)
        let transform = PixelFilter.placement(of: rect, in: edit.transform, width: source.width, height: source.height)
        edit.finishDetailTask = Task { @MainActor [weak edit] in
            // Wait for the view and sliders to settle; the preview keeps up in the meantime.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard let crop = source.cropping(to: rect) else { edit?.finishDetailPending = nil; return }
            let job = FilterJob(kind: .renderFinish, image: crop, settings: settings, scale: 1, selection: selection,
                                mapping: mapping, seed: seed, finishRegion: region)
            let image = await Task.detached(priority: .userInitiated) { try? PixelFilter.run(job) }.value
            guard let edit, !Task.isCancelled, edit.finishDetailPending == request else { return }
            edit.finishDetailPending = nil
            edit.finishDetailTask = nil
            // A failed render is retried the next time the canvas draws for another reason.
            guard let image else { return }
            edit.finishDetail = FinishDetail(request: request, image: image, transform: transform)
            redraw()
        }
    }
}
