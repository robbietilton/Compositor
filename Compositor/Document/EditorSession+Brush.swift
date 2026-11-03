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
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings(), growsMask: Bool = false,
                        seed: UInt64? = nil, useGPU: Bool = true) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        pauseGIFForEditing(for: layer.id)
        let sourceLayer = pixelEditingLayer(for: layer)
        let stroke = try BrushStroke(layer: sourceLayer, mask: isMaskSelected, settings: settings, canvas: document.size, useGPU: useGPU,
                                     growsMask: growsMask, seed: seed ?? UInt64.random(in: .min ... .max))
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
    func beginBrush(at point: CGPoint, pressure: CGFloat? = nil, input: BrushInput? = nil, seed: UInt64? = nil,
                    deferTaperRendering: Bool = false, useGPU: Bool = true) {
        BrushPerformanceSignpost.measure("Brush Input Begin") {
            beginBrushImpl(at: point, pressure: pressure, input: input, seed: seed,
                deferTaperRendering: deferTaperRendering, useGPU: useGPU)
        }
    }

    private func beginBrushImpl(at point: CGPoint, pressure: CGFloat?, input: BrushInput?, seed: UInt64?,
                                deferTaperRendering: Bool, useGPU: Bool) {
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
            if tool != .brush {
                settings.pressureSize = false; settings.pressureOpacity = false
                settings.roundDynamics = RoundBrushDynamics(); settings.shapeTip = nil
            }
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: tool == .brush,
                seed: seed, useGPU: useGPU)
            let strokeID = ObjectIdentifier(stroke)
            stroke.onGPUPreview = { [weak self] in
                guard let self, self.brushStroke.map(ObjectIdentifier.init) == strokeID else { return }
                self.brushRevision += 1
                self.refreshCanvasPreview?()
            }
            stroke.onGPUError = { [weak self] message in
                guard let self, self.brushStroke.map(ObjectIdentifier.init) == strokeID else { return }
                self.cancelBrush()
                self.brushError = message
                self.refreshCanvasPreview?()
            }
            stroke.defersTaperRendering = deferTaperRendering
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
            brushStroke = stroke
            brushInput = input ?? BrushInput(pressure: pressure)
            try stroke.append(point, input: brushInput)
            brushAnchor = point
            brushPointer = point
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint, pressure: CGFloat? = nil, input: BrushInput? = nil) {
        BrushPerformanceSignpost.measure("Brush Input Continue") {
            continueBrushImpl(at: point, pressure: pressure, input: input)
        }
    }

    func continueBrush(batch: [BrushStroke.InputSample]) {
        guard !batch.isEmpty else { return }
        BrushPerformanceSignpost.measure("Brush Input Batch") {
            if let warpStroke {
                for sample in batch { warpStroke.append(sample.point); lastBrushPoint?.point = sample.point }
                brushRevision += batch.count
                return
            }
            guard let brushStroke else { return }
            if !pendingBrushInputSamples.isEmpty {
                do { try flushQueuedBrushInputSamples() }
                catch { cancelBrush(); brushError = error.localizedDescription; return }
            }
            var prepared: [BrushStroke.InputSample] = []
            prepared.reserveCapacity(batch.count)
            for sample in batch {
                if let next = prepareBrushInput(at: sample.point, pressure: nil, input: sample.input) {
                    prepared.append(next)
                }
            }
            do {
                try brushStroke.append(batch: prepared)
                if let last = prepared.last { lastBrushPoint?.point = last.point }
            }
            catch { cancelBrush(); brushError = error.localizedDescription }
        }
    }

    func queueBrushInput(at point: CGPoint, input: BrushInput) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        if pendingBrushInputSamples.count == BrushStroke.maxInputSamplesPerBatch {
            do { try flushQueuedBrushInputSamples() }
            catch { cancelBrush(); brushError = error.localizedDescription; return }
        }
        guard let sample = prepareBrushInput(at: point, pressure: nil, input: input) else { return }
        pendingBrushInputSamples.append(sample)
    }

    func flushQueuedBrushInputSamples() throws {
        guard !pendingBrushInputSamples.isEmpty else { return }
        let samples = pendingBrushInputSamples
        pendingBrushInputSamples.removeAll(keepingCapacity: true)
        guard let brushStroke else { return }
        do {
            try brushStroke.append(batch: samples)
            if let last = samples.last { lastBrushPoint?.point = last.point }
        }
        catch { cancelBrush(); throw error }
    }

    private func continueBrushImpl(at point: CGPoint, pressure: CGFloat?, input: BrushInput?) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        guard let brushStroke else { return }
        if !pendingBrushInputSamples.isEmpty {
            do { try flushQueuedBrushInputSamples() }
            catch { cancelBrush(); brushError = error.localizedDescription; return }
        }
        guard let sample = prepareBrushInput(at: point, pressure: pressure, input: input) else { return }
        do { try brushStroke.append(sample.point, input: sample.input); lastBrushPoint?.point = sample.point }
        catch { cancelBrush(); brushError = error.localizedDescription }
    }

    private func prepareBrushInput(at point: CGPoint, pressure: CGFloat?, input: BrushInput?) -> BrushStroke.InputSample? {
        guard let brushStroke else { return nil }
        if let input, input.deviceID != brushInput.deviceID { return nil }
        let rawPrevious = brushPointer ?? point
        brushPointer = point
        let previousInput = brushInput
        if let input { brushInput = input.monotonic(after: previousInput.timestamp) }
        else if let pressure {
            brushInput = BrushInput(pressure: pressure, tilt: brushInput.tilt, rotation: brushInput.rotation,
                timestamp: brushInput.timestamp, deviceID: brushInput.deviceID)
        }
        let stabilization = brushStroke.settings.roundDynamics.stabilization ?? BrushStabilization()
        if let pressure = brushInput.pressure, let previous = previousInput.pressure {
            brushInput = BrushInput(pressure: previous + (pressure - previous) * (1 - 0.95 * stabilization.pressure),
                tilt: brushInput.tilt, rotation: brushInput.rotation, timestamp: brushInput.timestamp, deviceID: brushInput.deviceID)
        }
        let filtered = stabilization.point(point, previous: brushAnchor ?? point, rawPrevious: rawPrevious, zoom: viewport.zoom)
        // Smoothing filters position, never a stationary pressure/orientation change.
        guard let painted = smoothed(filtered) ?? (brushInput != previousInput ? brushAnchor : nil) else { return nil }
        brushAnchor = painted
        brushRevision += 1
        return BrushStroke.InputSample(point: painted, input: brushInput)
    }
    /// Where the brush actually is, with Smoothing on: it trails the pointer on a string, and only
    /// moves once the pointer pulls that string taut — the model Photoshop uses. The string's length
    /// is in screen points, so it feels the same however far the canvas is zoomed in. Nil while the
    /// string is still slack, which is the whole point: those jitters never reach the stroke.
    private func smoothed(_ point: CGPoint) -> CGPoint? {
        let smoothing = brushStroke?.settings.smoothing ?? brushSettings.smoothing
        guard tool == .brush, smoothing > 0, let anchor = brushAnchor else { return point }
        guard let moved = BrushStabilization.follow(point, from: anchor, radius: smoothing / max(0.01, viewport.zoom)) else { return nil }
        brushAnchor = moved
        return moved
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    func cancelBrush() {
        pendingBrushInputSamples.removeAll(keepingCapacity: true)
        warpStroke = nil
        brushStroke?.cancelPendingGPUWork()
        brushStroke = nil
        brushAnchor = nil
        brushPointer = nil
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        BrushPerformanceSignpost.measure("Brush Mouse Up Commit and Undo") {
            finishBrushImmediatelyImpl()
        }
    }

    private func finishBrushImmediatelyImpl() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard let stroke = brushStroke else { return true }
        guard !isProjectBusy else { return false }
        defer { cancelBrush() }
        do {
            try flushQueuedBrushInputSamples()
            // Smoothing leaves the brush short of the pointer; the stroke ends where the hand did.
            if let pointer = brushPointer, let anchor = brushAnchor, pointer != anchor,
               tool == .brush, (stroke.settings.smoothing > 0 || stroke.settings.roundDynamics.stabilization?.isActive == true) {
                try stroke.append(pointer, input: brushInput)
            }
            try stroke.flush()
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
              let current = document?.layers[index], pixelEditTransformMatches(current, original: stroke.layer) else { return }
        guard pixelEditTargetMatches(current, original: stroke.layer) else { return }
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
