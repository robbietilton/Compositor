import AppKit

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        let targetMask = activeLayer.flatMap { selectedMask(for: $0) }
        // A folder has no pixels of its own, so only its mask can be painted.
        return canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || targetMask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
    }
    /// Why a stroke can't start on the target, for the alert, as Photoshop explains a brush it refuses. Nil when
    /// nothing about the target is in the way; while the editor is busy (a transform, a dialog) a press just waits.
    var paintRefusal: String? {
        guard canEditLayers, let layer = activeLayer, !canPaint else { return nil }
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
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings(), growsMask: Bool = false,
                        useGPU: Bool = true) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        pauseGIFForEditing(for: layer.id)
        let sourceLayer = pixelEditingLayer(for: layer)
        let stroke = try BrushStroke(layer: sourceLayer, mask: isMaskSelected, settings: settings, canvas: document.size,
                                     useGPU: useGPU, growsMask: growsMask)
        func maskPixels(_ candidate: ImageLayer) -> Int {
            candidate.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0
        }
        let used = document.layers.reduce(0) { total, candidate in
            if isMaskSelected { return total + maskPixels(candidate) }
            let base = candidate.id == layer.id && layer.gifAnimation == nil ? 0
                : (candidate.asset.map { $0.image.width * $0.image.height } ?? 0)
            let frames = candidate.gifAnimation?.framePixels.filter {
                candidate.id != layer.id || $0.key != sourceLayer.gifAnimation?.selectedFrameIndex
            }.values.reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0
            return total + base + frames
        }
        stroke.pixelLimit = DocumentLimits.documentPixelBudget - used
        stroke.selectionClip = try selection?.clip(canvas: document.size)
        if !isMaskSelected, layer.mask != nil {
            let usedMasks = document.layers.reduce(0) { $0 + maskPixels($1) }
            stroke.pixelLimit = min(stroke.pixelLimit, DocumentLimits.documentPixelBudget - usedMasks)
        }
        return stroke
    }
    /// `pressure` is a pen's, 0–1; nil for a mouse or trackpad, which presses fully.
    func beginBrush(at point: CGPoint, pressure: CGFloat? = nil) {
        // Spot Healing and Clone Stamp rework image pixels; they have nothing to do on a mask.
        if tool == .blur, blurMode != .blur { beginWarp(at: point); return }
        guard tool == .brush || tool == .blur || (tool.isBrushTool && !isMaskSelected) else { return }
        guard canPaint, let layer = activeLayer, let document else { brushError = paintRefusal; return }
        var sourceOffset: CGSize?
        if tool == .cloneStamp {
            guard let offset = cloneStrokeOffset(at: point) else {
                brushError = "Option-click where Clone Stamp should copy from first."
                return
            }
            sourceOffset = offset
        }
        finishOpacityEdit()
        do {
            var settings = brushSettings
            settings.healing = tool == .spotHealing
            settings.erasing = tool == .brush && brushMode == .erase && !isMaskSelected
            settings.healingMode = spotHealingMode
            // The pressure buttons belong to the Brush; the other brush tools paint at full pressure.
            if tool != .brush { settings.pressureSize = false; settings.pressureOpacity = false }
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            var stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: tool == .brush)
            if let offset = sourceOffset {
                guard let sample = cloneSample(document, for: stroke, offset: offset) else { return }
                cloneOffset = offset
                stroke.clone = sample
            }
            // Blur paints a softened copy of the layer, in place, through the brush tip.
            if tool == .blur {
                guard let blur = blurSample(for: stroke) else { return }
                stroke.clone = blur.sample
                stroke.cloneRender = blur.render
                if let deepRender = blur.deepRender {
                    stroke.deepClone = blur.sample
                    stroke.deepCloneRender = deepRender
                }
            }
            stroke.isBlur = tool == .blur
            limitGrowth(of: stroke)
            // A layer scaled so far down that paint across the canvas would outgrow it, and a stroke starting past its
            // edges: the stroke is likely to outgrow it, so it starts on the layer at its displayed size rather than
            // being painted again partway through, which would stall it for a moment.
            if let limit = stroke.growthLimit, stroke.width * stroke.height > limit, stroke.reachesPastSource(at: point) {
                let resized = try makeRasterEdit(for: try Self.atDisplayedSize(stroke.layer), settings: settings,
                                                 growsMask: tool == .brush)
                resized.originalLayer = stroke.originalLayer
                stroke = resized
            }
            brushStroke = stroke
            brushInput = []
            brushPressure = pressure ?? 1
            try appendToBrush(point, pressure: brushPressure)
            brushAnchor = point
            brushPointer = point
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint, pressure: CGFloat? = nil) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        guard let brushStroke else { return }
        brushPointer = point
        if let pressure { brushPressure = pressure }
        guard let painted = smoothed(point) else { return }
        do { try appendToBrush(painted, pressure: brushPressure); lastBrushPoint?.point = painted; brushRevision += 1 }
        catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// Where the brush actually is, with Smoothing on: it trails the pointer on a string, and only
    /// moves once the pointer pulls that string taut — the model Photoshop uses. The string's length
    /// is in screen points, so it feels the same however far the canvas is zoomed in. Nil while the
    /// string is still slack, which is the whole point: those jitters never reach the stroke.
    private func smoothed(_ point: CGPoint) -> CGPoint? {
        guard tool == .brush, brushSettings.smoothing > 0, let anchor = brushAnchor else { return point }
        let radius = brushSettings.smoothing / max(0.01, viewport.zoom)
        let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
        let distance = hypot(delta.x, delta.y)
        guard distance > radius else { return nil }
        let step = (distance - radius) / distance
        let moved = CGPoint(x: anchor.x + delta.x * step, y: anchor.y + delta.y * step)
        brushAnchor = moved
        return moved
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    /// A layer scaled down keeps its own pixels, so scaling it back up stays sharp, and paint past its edges grows it at
    /// that resolution. Scaled far down and painted well past its edges, that would take many times the pixels it shows:
    /// enough to run the GPU out of memory. So a Brush stroke on one may grow it only so far before it is painted again
    /// on the layer at its displayed size.
    private func limitGrowth(of stroke: BrushStroke) {
        let layer = stroke.layer
        guard tool == .brush, !stroke.isMask, layer.gifAnimation == nil, let asset = layer.asset, asset.deep == nil,
              let document else { return }
        let own = CGFloat(asset.image.width * asset.image.height)
        guard layer.transform.size.width * layer.transform.size.height < own * 0.98 else { return }
        // As much as the Blur tool allows itself: four canvases' worth, and never less than 16 megapixels.
        let canvas = document.size.width * document.size.height
        let budget = min(CGFloat(DocumentLimits.maxSurfacePixels), max(16_000_000, 4 * canvas))
        stroke.growthLimit = Int(max(budget, own * 2))
    }

    /// The layer's pixels resampled to the size it's shown at, so it is no longer scaled.
    static func atDisplayedSize(_ layer: ImageLayer) throws -> ImageLayer {
        guard let asset = layer.asset else { return layer }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.interpolationQuality = .high
        BrushRaster.draw(asset.image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let image = context.makeImage() else { throw ProjectError.tooLarge }
        var resized = layer
        resized.asset = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: asset.name)
        return resized
    }

    private func appendToBrush(_ point: CGPoint, pressure: CGFloat) throws {
        brushInput.append((point, pressure))
        try recovering(again: false) { try $0.append(point, pressure: pressure) }
    }

    /// Runs `work` on the stroke in progress. When it outgrows its layer's resolution, or the GPU fails, the stroke is
    /// started again — on the layer at its displayed size, or on the CPU — and painted from its first point, so it
    /// carries on as if nothing had happened. `again` runs `work` once more on the new stroke; an append needn't, as
    /// the replay includes its point.
    private func recovering(again: Bool, _ work: (BrushStroke) throws -> Void) throws {
        guard let stroke = brushStroke else { return }
        do {
            try work(stroke)
            return
        } catch is BrushStroke.OutgrewItsResolution {
            try restartBrush(from: stroke, atDisplayedSize: true, onGPU: stroke.usesGPU)
        } catch is MetalBrushCoverage.Failed {
            try restartBrush(from: stroke, atDisplayedSize: false, onGPU: false)
        }
        if again { try recovering(again: true, work) }
    }

    /// Starts the stroke again from its first point: on the layer resampled to its displayed size, or on the CPU.
    private func restartBrush(from stroke: BrushStroke, atDisplayedSize: Bool, onGPU: Bool) throws {
        let layer = atDisplayedSize ? try Self.atDisplayedSize(stroke.layer) : stroke.layer
        let fresh = try makeRasterEdit(for: layer, settings: stroke.settings, growsMask: tool == .brush, useGPU: onGPU)
        fresh.originalLayer = stroke.originalLayer
        fresh.clone = stroke.clone
        fresh.cloneRender = stroke.cloneRender
        fresh.deepClone = stroke.deepClone
        fresh.deepCloneRender = stroke.deepCloneRender
        fresh.isBlur = stroke.isBlur
        fresh.replacesWithClone = stroke.replacesWithClone
        fresh.editName = stroke.editName
        limitGrowth(of: fresh)
        brushStroke = fresh
        do {
            try fresh.replay(brushInput)
        } catch is BrushStroke.OutgrewItsResolution {
            try restartBrush(from: fresh, atDisplayedSize: true, onGPU: onGPU)
        } catch is MetalBrushCoverage.Failed where onGPU {
            try restartBrush(from: fresh, atDisplayedSize: false, onGPU: false)
        }
    }

    func cancelBrush() {
        brushInput = []
        warpStroke = nil
        brushStroke = nil
        brushAnchor = nil
        brushPointer = nil
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard brushStroke != nil else { return true }
        guard !isProjectBusy else { return false }
        defer { cancelBrush() }
        do {
            // Smoothing leaves the brush short of the pointer; the stroke ends where the hand did.
            if let pointer = brushPointer, let anchor = brushAnchor, pointer != anchor,
               tool == .brush, brushSettings.smoothing > 0 {
                try appendToBrush(pointer, pressure: brushPressure)
            }
            try recovering(again: true) { try $0.flush() }
            // Painting may have started the stroke again, on the layer at its displayed size or on the CPU.
            guard let stroke = brushStroke else { return true }
            if stroke.settings.healing { try stroke.heal() }
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
        return true
    }

    func finishBrush() async { finishBrushImmediately() }

    /// Install immutable tiles immediately, including the undo entry. The next
    /// stroke and other tools can start without awaiting full-image assembly.
    func commitPaintSnapshot(_ stroke: BrushStroke) throws {
        let result = try stroke.paintSnapshot()
        guard result.transform.isValid,
              let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], pixelEditTransformMatches(current, original: stroke.originalLayer) else { return }
        guard pixelEditTargetMatches(current, original: stroke.originalLayer) else { return }
        var mask = current.mask
        if !stroke.isMask, current.gifAnimation == nil, let original = mask, original.placement == nil, result.bounds != stroke.sourceRect {
            let raster = RasterSnapshot.replacing(source: original.asset, sourceRect: stroke.sourceRect,
                patches: [], crop: result.bounds, isMask: true)
            mask = original.replacing(ImportedImage(image: try raster.makeImage(), thumbnail: try raster.thumbnail(),
                name: original.asset.name, raster: raster))
        }
        let edited = stroke.isMask ? nil : try layerByEditingPixels(current, asset: result.asset, transform: result.transform, mask: mask)
        beginEdit(stroke.editName ?? (stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.isBlur ? "Blur" : stroke.clone != nil ? "Clone Stamp" : stroke.settings.healing ? "Spot Healing" : "Brush Stroke"))
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { mask in
                var painted = mask.replacing(result.asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document. A linked
                // one still moves with its layer.
                if mask.placement != nil || result.bounds != stroke.sourceRect { painted.placement = result.transform }
                if current.gifAnimation != nil {
                    painted.placement = painted.placement(movingLayer: stroke.layer.transform, to: current.transform)
                }
                return painted
            } ?? LayerMask(asset: result.asset)
        } else if let edited { document?.layers[index] = edited }
        endEdit()
    }

    /// Assembles a raster edit off the main thread and replaces the layer's pixels or
    /// mask as one undo step. Other layer properties are read at commit time.
    func commitRasterEdit(_ stroke: BrushStroke, name: String, alsoApply: (() -> Void)? = nil) async throws {
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard stroke.committedTransform.isValid else { throw ProjectError.tooLarge }
        let input = stroke.commitInput()
        let result = try await BrushCommit.shared.render(input)
        let asset = result.asset
        let transform = stroke.transform(for: result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY))
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = stroke.layer.mask
        if !stroke.isMask, stroke.layer.gifAnimation == nil, let originalMask = mask, originalMask.placement == nil {
            mask = originalMask.replacing(try await BrushCommit.shared.expandMask(originalMask.asset, for: input, croppedTo: result.pixelBounds))
        }
        // The raster was built from this layer's pixels, transform, and mask; never
        // write it over content that changed underneath it.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], pixelEditTransformMatches(current, original: stroke.layer) else { return }
        guard pixelEditTargetMatches(current, original: stroke.layer),
              current.mask?.asset.image === stroke.layer.mask?.asset.image else { return }
        let keptMask = mask.map { mask -> LayerMask in
            var kept = mask
            kept.isEnabled = current.mask?.isEnabled ?? mask.isEnabled
            return kept
        }
        let edited = stroke.isMask ? nil : try layerByEditingPixels(current, asset: asset, transform: transform, mask: keptMask)
        beginEdit(name)
        if stroke.isMask {
            let bounds = result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY)
            document?.layers[index].mask = current.mask.map { mask in
                var edited = mask.replacing(asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document.
                if mask.placement != nil || bounds != stroke.sourceRect { edited.placement = transform }
                if current.gifAnimation != nil {
                    edited.placement = edited.placement(movingLayer: stroke.layer.transform, to: current.transform)
                }
                return edited
            } ?? LayerMask(asset: asset)
        } else if let edited { document?.layers[index] = edited }
        alsoApply?()
        endEdit()
    }
    /// Tools where number keys set opacity: the brush or gradient opacity, or with
    /// Move/Transform and the selection tools the opacity of the selected layers.
    var usesOpacityKeys: Bool { tool.isBrushTool || tool == .gradient || tool == .move || tool.isSelectionTool }

    /// Photoshop-style opacity keys: 1 = 10% … 9 = 90%, 0 = 100%.
    /// Two digits typed quickly set an exact value (4 then 5 = 45%, 0 then 5 = 5%).
    func typeOpacityDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesOpacityKeys, brushStroke == nil, !isProjectBusy, (0...9).contains(digit) else { return }
        var percent = digit == 0 ? 100 : digit * 10
        if let pending = pendingOpacityDigit, time - pending.time < 0.6 {
            percent = max(1, pending.digit * 10 + digit)
            pendingOpacityDigit = nil
        } else {
            pendingOpacityDigit = (digit, time)
        }
        let value = CGFloat(percent) / 100
        switch tool {
        case .brush, .spotHealing, .cloneStamp, .blur: brushSettings.opacity = value
        case .gradient: gradientSettings.opacity = value
        default: setSelectedLayersOpacity(Double(value))
        }
    }
    /// Shift-[ / Shift-]: hardness in Photoshop's 25% steps (0, 25, 50, 75, 100%).
    func changeBrushHardness(increase: Bool) {
        guard brushStroke == nil else { return }
        // Snap to the next step up or down, so 80% goes to 100% or 75%.
        let quarter = brushSettings.hardness * 4
        let step = increase ? floor(quarter + 0.001) + 1 : ceil(quarter - 0.001) - 1
        brushSettings.hardness = min(4, max(0, step)) / 4
    }
    func changeBrushSize(increase: Bool) {
        guard brushStroke == nil else { return }
        // A step of a fifth, but always at least one pixel: 2 shrunk by a fifth would otherwise round back to 2,
        // leaving the smallest brushes out of reach.
        let current = brushSettings.diameter
        let stepped = increase ? max(current + 1, (current * 1.2).rounded()) : min(current - 1, (current / 1.2).rounded())
        brushSettings.diameter = min(2000, max(1, stepped))
    }
}
