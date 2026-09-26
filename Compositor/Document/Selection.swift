import AppKit
import CoreImage

/// A document-space selection outline, clipped to the canvas. `nil` on the document
/// means no selection; a selection whose path is empty is an explicit empty selection,
/// which later edits must treat as "touch nothing", never as "touch everything".
nonisolated struct DocumentSelection: Equatable, @unchecked Sendable {
    let path: CGPath
    var antialiased = true
    /// How far the edge fades, in document pixels. 0 is a hard edge.
    var feather: CGFloat = 0
    var isEmpty: Bool { path.isEmpty || path.boundingBoxOfPath.isNull || path.boundingBoxOfPath.isEmpty }

    /// Grayscale coverage at document resolution (white = selected), top-left origin.
    func coverage(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(antialiased || feather > 0)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else { throw ExportError.render }
        guard feather > 0 else { return image }
        // A feathered edge fades either side of the outline, as Photoshop's does.
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let soft = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: feather / 2).cropped(to: extent)
        return try PixelAdjust.render(soft, width: width, height: height, isMask: true)
    }
}

extension DocumentSelection {
    /// Four Gaussian standard deviations retain the visible falloff outside the outline.
    var coverageBounds: CGRect {
        path.boundingBoxOfPath.insetBy(dx: -ceil(feather * 2), dy: -ceil(feather * 2))
    }

    /// Coverage for just the selected region of the canvas, ready to clip edits.
    func clip(canvas size: CGSize) throws -> SelectionClip {
        let region = coverageBounds.insetBy(dx: -1, dy: -1).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard !isEmpty, !region.isNull, region.width >= 1, region.height >= 1 else { return SelectionClip(rect: .zero, coverage: nil) }
        var translation = CGAffineTransform(translationX: -region.minX, y: -region.minY)
        guard let localPath = path.copy(using: &translation) else { throw ExportError.render }
        let local = DocumentSelection(path: localPath, antialiased: antialiased, feather: feather)
        let image = try local.coverage(width: Int(region.width), height: Int(region.height))
        return SelectionClip(rect: region, coverage: image)
    }
}

/// Selection coverage for one region of the document. Applied as a clip, soft edges
/// blend partially; with no coverage (an empty selection) it clips everything away.
nonisolated struct SelectionClip: @unchecked Sendable {
    let rect: CGRect
    let coverage: CGImage?

    /// Clips a context whose current coordinates are document pixels (top-left origin).
    func apply(to context: CGContext) {
        guard let coverage, !rect.isEmpty else { context.clip(to: CGRect.zero); return }
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: rect.size), mask: coverage)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.maxY)
    }
}

/// The Magic tool's modes: Wand selects pixels of a similar color, Object traces the outline of
/// whatever the click lands on. Tab switches between them, as with the Brush's Paint and Erase.
nonisolated enum WandMode: String, CaseIterable, Sendable {
    case wand = "Wand"
    case object = "Object"
}

nonisolated enum LassoKind: String, CaseIterable, Sendable {
    case freehand = "Freehand"
    case polygonal = "Polygonal"
    case magnetic = "Magnetic"
    /// The Marquee's outlines; not offered in the Lasso's Freehand/Polygonal choice.
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    static let lassoChoices: [LassoKind] = [.freehand, .polygonal]
    static let marqueeChoices: [LassoKind] = [.rectangle, .ellipse]
}

nonisolated enum SelectionMode: String, CaseIterable, Sendable {
    case replace = "New"
    case add = "Add"
    case subtract = "Subtract"
}

/// The box a drag from `anchor` to `point` spans, in whole pixels. `square` evens the sides;
/// `fromCenter` grows the box around the anchor. Shared by the Marquee and the Shape tool.
nonisolated enum DragBox {
    static func rect(from anchor: CGPoint, to point: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = point.x.rounded() - anchor.x, dy = point.y.rounded() - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return fromCenter
            ? CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            : CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
    }
}

/// A lasso outline being drawn, in document pixels. `cursor` is the polygonal lasso's
/// rubber-band end point.
struct LassoDraft {
    var points: [CGPoint]
    var cursor: CGPoint?
    let mode: SelectionMode
    let kind: LassoKind
    /// The Rectangular Marquee's starting corner (or center), in whole pixels.
    var anchor: CGPoint?
}

/// A brush-driven selection gesture. The image sample is kept privately by the session so
/// the draft remains lightweight while analysis runs off the main actor.
struct QuickSelectionDraft: Equatable {
    var points: [CGPoint]
    let mode: SelectionMode
}

extension EditorSession {
    var selection: DocumentSelection? { document?.selection }
    var canEditSelection: Bool { canEditLayers }

    /// Shift adds, Option (with or without Shift) subtracts; otherwise the options-bar mode.
    func selectionMode(shift: Bool, option: Bool) -> SelectionMode {
        option ? .subtract : shift ? .add : selectionModeChoice
    }

    /// The mode the cursor advertises: an outline in progress keeps its starting mode,
    /// otherwise the currently held modifiers or the options-bar choice.
    func lassoCursorMode(shift: Bool, option: Bool) -> SelectionMode {
        quickSelectionDraft?.mode ?? lassoDraft?.mode ?? selectionMode(shift: shift, option: option)
    }

    /// What the options bar highlights: the same rule, using the tracked held keys.
    var displayedSelectionMode: SelectionMode { quickSelectionDraft?.mode ?? lassoDraft?.mode ?? heldSelectionMode ?? selectionModeChoice }

    func updateHeldSelectionKeys(shift: Bool, option: Bool) {
        let held: SelectionMode? = option ? .subtract : shift ? .add : nil
        if heldSelectionMode != held { heldSelectionMode = held }
    }

    func beginLasso(at point: CGPoint, mode: SelectionMode) {
        // Click-selection tools never draw a draft outline.
        guard tool.isSelectionTool, tool != .wand, tool != .quickSelection, canEditSelection, selectionMoveOrigin == nil else { return }
        if tool == .marquee {
            let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
            lassoDraft = LassoDraft(points: [anchor], cursor: nil, mode: mode, kind: marqueeKind, anchor: anchor)
        } else if tool == .magneticLasso {
            lassoDraft = LassoDraft(points: [point], cursor: point, mode: mode, kind: .magnetic)
            magneticLassoSample = document.flatMap { selectionSample($0, sampleAllLayers: wandSettings.sampleAllLayers) }
            magneticLassoPrepared = magneticLassoSample.flatMap(MagneticLasso.prepare)
        } else {
            lassoDraft = LassoDraft(points: [point], cursor: nil, mode: mode, kind: lassoKind)
        }
    }

    /// Marquee drag, snapped to whole pixels. Shift held during the drag makes a square (or
    /// circle); `fromCenter` grows the box around the anchor. The canvas never asks for that with
    /// Option, which subtracts from the selection instead.
    func dragMarquee(to point: CGPoint, square: Bool, fromCenter: Bool) {
        guard var draft = lassoDraft, draft.kind == .rectangle || draft.kind == .ellipse, let anchor = draft.anchor,
              point.x.isFinite, point.y.isFinite else { return }
        let rect = DragBox.rect(from: anchor, to: point, square: square, fromCenter: fromCenter)
        draft.points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        lassoDraft = draft
    }

    /// Adds an outline point; points closer than a quarter pixel are skipped.
    func extendLasso(to point: CGPoint) {
        guard var draft = lassoDraft, point.x.isFinite, point.y.isFinite else { return }
        if let last = draft.points.last, hypot(point.x - last.x, point.y - last.y) < 0.25 { return }
        draft.points.append(point)
        lassoDraft = draft
    }

    /// Adds a click anchor to the Magnetic Lasso. The moving cursor is kept separately so the
    /// overlay can show the rubber-band segment without creating history on every pointer event.
    func addMagneticLassoPoint(at point: CGPoint) {
        guard tool == .magneticLasso, lassoDraft?.kind == .magnetic else { return }
        let anchor: CGPoint
        if let draft = lassoDraft, let last = draft.points.last, let prepared = magneticLassoPrepared {
            anchor = MagneticLasso.snap(in: prepared, from: last, to: point, settings: magneticLassoSettings) ?? point
        } else {
            anchor = point
        }
        extendLasso(to: anchor)
        moveLassoCursor(to: anchor)
    }

    func beginMagneticLasso(at point: CGPoint, mode: SelectionMode) {
        guard tool == .magneticLasso else { return }
        beginLasso(at: point, mode: mode)
    }

    /// Updates the live Magnetic Lasso segment by snapping it to the strongest nearby edge.
    func continueMagneticLasso(to point: CGPoint) {
        guard tool == .magneticLasso, let draft = lassoDraft, draft.kind == .magnetic,
              let last = draft.points.last, let prepared = magneticLassoPrepared else {
            moveLassoCursor(to: point)
            return
        }
        let snapped = MagneticLasso.snap(in: prepared, from: last, to: point, settings: magneticLassoSettings) ?? point
        moveLassoCursor(to: snapped)
    }

    func moveLassoCursor(to point: CGPoint?) { lassoDraft?.cursor = point }

    func removeLastLassoPoint() {
        guard var draft = lassoDraft else { return }
        draft.points.removeLast()
        lassoDraft = draft.points.isEmpty ? nil : draft
    }

    func cancelLasso() {
        lassoDraft = nil
        magneticLassoSample = nil
        magneticLassoPrepared = nil
        cancelQuickSelectionAnalysis()
    }

    /// The M key chooses the Marquee in whichever shape it was last set to (switched only in the tool bar). The
    /// shape stays as last set while this project is open.
    func pressMarqueeKey() {
        selectTool(.marquee)
    }

    func toggleMarqueeKind() {
        cancelLasso()
        marqueeKind = marqueeKind == .rectangle ? .ellipse : .rectangle
    }

    /// W cycles the Magic selection group: Wand, Object, and Quick Selection.
    func pressWandKey() {
        if tool == .wand {
            if wandMode == .wand { wandMode = .object }
            else { selectTool(.quickSelection) }
        } else if tool == .quickSelection {
            wandMode = .wand
            selectTool(.wand)
        } else {
            selectTool(.wand)
        }
    }

    /// The L key chooses the Lasso in whichever mode it was last set to (switched only in the tool bar). The mode
    /// stays as last set while this project is open.
    func pressLassoKey() {
        selectTool(.lasso)
    }

    func toggleLassoKind() {
        cancelLasso()
        lassoKind = lassoKind == .freehand ? .polygonal : .freehand
    }

    /// Starts a Quick Selection brush gesture without touching history. The image sample is
    /// captured at the beginning so one drag has stable pixels even if the pointer moves quickly.
    func beginQuickSelection(at point: CGPoint, mode: SelectionMode) {
        guard tool == .quickSelection, canEditSelection, selectionMoveOrigin == nil,
              let document, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: wandSettings.sampleAllLayers) else { return }
        cancelQuickSelectionAnalysis()
        quickSelectionSample = sample
        quickSelectionPrepared = nil
        quickSelectionPreviewPointCount = 0
        quickSelectionSettingsAtStart = quickSelectionSettings
        quickSelectionDraft = QuickSelectionDraft(points: [point], mode: mode)
        scheduleQuickSelectionPreview()
    }

    /// Extends the current Quick Selection brush path, skipping sub-pixel pointer noise.
    func continueQuickSelection(to point: CGPoint) {
        guard var draft = quickSelectionDraft, point.x.isFinite, point.y.isFinite else { return }
        if let last = draft.points.last, hypot(point.x - last.x, point.y - last.y) < 0.25 { return }
        draft.points.append(point)
        quickSelectionDraft = draft
        scheduleQuickSelectionPreview()
    }

    /// Commits a Quick Selection gesture as one undo step after deterministic mask analysis.
    func finishQuickSelection() async {
        guard let draft = quickSelectionDraft, let sample = quickSelectionSample,
              let settings = quickSelectionSettingsAtStart, let document else { return }
        quickSelectionPreviewTask?.cancel()
        quickSelectionPreviewTask = nil
        quickSelectionPreviewRequest &+= 1
        let generation = quickSelectionGeneration
        let prepared = quickSelectionPrepared
        let previousMask = quickSelectionPreviewMask
        let processedPointCount = quickSelectionPreviewPointCount
        quickSelectionDraft = nil
        quickSelectionSample = nil
        quickSelectionPrepared = nil
        quickSelectionPreviewPointCount = 0
        quickSelectionSettingsAtStart = nil
        let points = previousMask == nil ? draft.points : Array(draft.points.dropFirst(processedPointCount))
        let mask = await Task.detached(priority: .userInitiated) {
            guard let raster = prepared ?? QuickSelection.prepare(sample) else { return nil as [UInt8]? }
            if points.isEmpty { return previousMask }
            return QuickSelection.mask(in: raster, points: points, settings: settings,
                                       previousMask: previousMask)
        }.value
        guard self.document?.id == document.id, self.quickSelectionGeneration == generation, let mask else { return }
        guard let outline = quickSelectionOutline(of: mask, document: document) else {
            clearQuickSelectionPreview()
            return
        }
        if draft.mode == .replace {
            setSelection(DocumentSelection(path: outline, antialiased: selectionAntialiased), name: "Quick Selection")
        } else if draft.mode == .subtract, mask.allSatisfy({ $0 == 255 }), let current = selection,
                  current.path.boundingBoxOfPath.intersects(CGRect(origin: .zero, size: document.size)) {
            // A full-canvas subtraction should become the model's explicit empty selection.
            // Some CGPath Boolean implementations leave a zero-area boundary path behind.
            setSelection(DocumentSelection(path: CGMutablePath(), antialiased: selectionAntialiased), name: "Quick Selection")
        } else {
            applySelection(outline, mode: draft.mode, name: "Quick Selection")
        }
        clearQuickSelectionPreview()
    }

    /// Cancels analysis and removes only the transient Quick Selection state.
    /// The document selection and history are intentionally untouched.
    private func cancelQuickSelectionAnalysis() {
        quickSelectionPreviewTask?.cancel()
        quickSelectionPreviewTask = nil
        quickSelectionPreviewRequest &+= 1
        quickSelectionGeneration &+= 1
        quickSelectionDraft = nil
        quickSelectionSample = nil
        quickSelectionPrepared = nil
        quickSelectionPreviewPointCount = 0
        quickSelectionSettingsAtStart = nil
        clearQuickSelectionPreview()
    }

    private func clearQuickSelectionPreview() {
        quickSelectionPreviewMask = nil
        quickSelectionPreviewOutline = nil
        refreshCanvasPreview?()
    }

    /// Coalesces pointer updates and analyses the captured image off the main actor. A token
    /// and document id prevent an older result from replacing a newer gesture or a new tab.
    private func scheduleQuickSelectionPreview() {
        guard quickSelectionDraft != nil, quickSelectionSample != nil,
              quickSelectionSettingsAtStart != nil, document != nil else { return }
        quickSelectionPreviewRequest &+= 1
        guard quickSelectionPreviewTask == nil else { return }
        quickSelectionPreviewTask = Task { @MainActor [weak self] in
            defer { self?.quickSelectionPreviewTask = nil }
            while let self, !Task.isCancelled {
                let request = self.quickSelectionPreviewRequest
                guard let draft = self.quickSelectionDraft,
                      let sample = self.quickSelectionSample,
                      let settings = self.quickSelectionSettingsAtStart,
                      let document = self.document else { return }
                // The first dab is published as soon as its detached analysis finishes. Later
                // points are coalesced for one display interval so a fast mouse stream cannot
                // build an unbounded queue of stale previews.
                if self.quickSelectionPreviewPointCount > 0 {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                guard !Task.isCancelled else { return }

                let generation = self.quickSelectionGeneration
                let documentID = document.id
                let processedPointCount = self.quickSelectionPreviewPointCount
                let previousMask = self.quickSelectionPreviewMask
                let points = previousMask == nil ? draft.points : Array(draft.points.dropFirst(processedPointCount))
                if points.isEmpty { return }
                let prepared = self.quickSelectionPrepared
                let result = await Task.detached(priority: .userInitiated) { () -> (QuickSelection.PreparedImage, [UInt8])? in
                    guard let raster = prepared ?? QuickSelection.prepare(sample),
                          let mask = QuickSelection.mask(in: raster, points: points,
                                                         settings: settings, previousMask: previousMask)
                    else { return nil }
                    return (raster, mask)
                }.value
                guard !Task.isCancelled, self.quickSelectionGeneration == generation,
                      self.document?.id == documentID, let (raster, mask) = result else { return }
                self.quickSelectionPrepared = raster
                self.quickSelectionPreviewPointCount = draft.points.count
                self.quickSelectionPreviewMask = mask
                self.quickSelectionPreviewOutline = self.quickSelectionOutline(of: mask, document: document)
                self.refreshCanvasPreview?()
                // A newer drag point may arrive while analysis runs. Show the completed
                // contour now, then catch up, rather than withholding every preview until
                // the pointer stops moving.
                if request == self.quickSelectionPreviewRequest { return }
            }
        }
    }

    private func quickSelectionOutline(of mask: [UInt8], document: CanvasDocument) -> CGPath? {
        try? MagicWand.displayOutline(of: mask, width: document.width, height: document.height)
    }

    /// Compatibility spelling used by the gesture tests and callers.
    func extendQuickSelection(to point: CGPoint) {
        continueQuickSelection(to: point)
    }
    /// Closes the outline and combines it with the current selection. A click that
    /// encloses nothing deselects in New mode, as in Photoshop.
    func finishLasso() {
        guard let draft = lassoDraft else { return }
        lassoDraft = nil
        defer {
            magneticLassoSample = nil
            magneticLassoPrepared = nil
        }
        if draft.kind == .magnetic {
            guard draft.points.count >= 3,
                  let prepared = magneticLassoPrepared ?? magneticLassoSample.flatMap(MagneticLasso.prepare),
                  let outline = MagneticLasso.path(in: prepared, anchors: draft.points, settings: magneticLassoSettings) else { return }
            applySelection(outline, mode: draft.mode, name: "Magnetic Lasso")
            return
        }
        let outline = CGMutablePath()
        if draft.kind == .ellipse, draft.points.count == 4 {
            // The drag's box, whole pixels like a rectangle; the oval fills it.
            let xs = draft.points.map(\.x), ys = draft.points.map(\.y)
            outline.addEllipse(in: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        } else {
            outline.addLines(between: draft.points)
            outline.closeSubpath()
        }
        let bounds = outline.boundingBoxOfPath
        guard draft.points.count >= 3 || draft.kind == .ellipse, bounds.width > 0, bounds.height > 0 else {
            if draft.mode == .replace { deselect() }
            return
        }
        applySelection(outline, mode: draft.mode,
                       name: draft.kind == .freehand ? "Lasso" : draft.kind == .polygonal ? "Polygonal Lasso"
                           : draft.kind == .magnetic ? "Magnetic Lasso"
                           : draft.kind == .ellipse ? "Elliptical Marquee" : "Rectangular Marquee")
    }

    func applySelection(_ shape: CGPath, mode: SelectionMode, name: String) {
        guard let document, canEditSelection else { return }
        let canvas = CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)
        let clipped = shape.intersection(canvas, using: .winding)
        let result: CGPath
        switch mode {
        case .replace: result = clipped
        case .add: result = selection.map { $0.path.union(clipped, using: .winding) } ?? clipped
        case .subtract:
            // Subtracting from no selection selects nothing new, so nothing changes.
            guard let current = selection else { return }
            result = current.path.subtracting(clipped, using: .winding)
        }
        setSelection(DocumentSelection(path: result, antialiased: selectionAntialiased), name: name)
    }

    func setSelection(_ value: DocumentSelection?, name: String) {
        guard document != nil, canEditSelection, value != selection else { return }
        beginEdit(name)
        document?.selection = value
        endEdit()
    }

    /// True where dragging in New mode would move the selection outline.
    func canMoveSelection(at point: CGPoint) -> Bool {
        guard let selection, !selection.isEmpty, canEditSelection, lassoDraft == nil else { return false }
        return selection.path.contains(point, using: .winding)
    }

    /// Moves the outline only (never pixels). The whole drag is one undo step.
    func beginSelectionMove() -> Bool {
        guard selectionMoveOrigin == nil, let selection, !selection.isEmpty, canEditSelection else { return false }
        beginEdit("Move Selection")
        selectionMoveOrigin = selection
        return true
    }

    /// Offsets from the drag's start, rounded to whole pixels so edges stay crisp. The
    /// outline is not re-clipped, so it can leave the canvas and come back intact.
    func moveSelection(by offset: CGSize) {
        guard let origin = selectionMoveOrigin else { return }
        var shift = CGAffineTransform(translationX: offset.width.rounded(), y: offset.height.rounded())
        guard let path = origin.path.copy(using: &shift) else { return }
        document?.selection = DocumentSelection(path: path, antialiased: origin.antialiased, feather: origin.feather)
    }

    func endSelectionMove() {
        guard selectionMoveOrigin != nil else { return }
        selectionMoveOrigin = nil
        endEdit()
    }

    /// Arrow-key nudge: 1 px, or 10 px with Shift. Each press is one undo step.
    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard beginSelectionMove() else { return }
        moveSelection(by: CGSize(width: dx, height: dy))
        endSelectionMove()
    }

    /// Expand / Contract need a non-empty selection to work on.
    var canModifySelection: Bool { selection?.isEmpty == false && canEditSelection && lassoDraft == nil }

    enum SelectionAmountOperation: String {
        case expand = "Expand", contract = "Contract", feather = "Feather"
    }

    /// Menu commands ask for an amount; the tool header applies its input directly.
    func promptSelectionAmount(_ operation: SelectionAmountOperation) {
        guard canModifySelection else { return }
        selectionAmountOperation = operation
    }

    func confirmSelectionAmount(_ amount: Int) {
        guard let operation = selectionAmountOperation,
              (1...(operation == .feather ? 250 : 500)).contains(amount) else { return }
        selectionAmountOperation = nil
        switch operation {
        case .expand: selectionExpandAmount = amount; expandSelection(by: amount)
        case .contract: selectionContractAmount = amount; contractSelection(by: amount)
        case .feather: selectionFeatherAmount = amount; featherSelection(by: amount)
        }
    }

    /// Grows the outline by `amount` pixels with rounded corners (Photoshop's Expand), clipped to the canvas.
    func expandSelection(by amount: Int) { resizeSelection(by: CGFloat(amount), name: "Expand Selection") }

    /// Shrinks the outline by `amount` pixels, including away from the canvas edges.
    /// Contracting past the middle leaves an explicit empty selection.
    func contractSelection(by amount: Int) { resizeSelection(by: -CGFloat(amount), name: "Contract Selection") }

    /// Softens the current selection's edge by `amount` pixels, as Select → Modify → Feather does. Applying it
    /// again softens further, the way Expand and Contract stack up.
    func featherSelection(by amount: Int) {
        guard canModifySelection, let current = selection, amount > 0 else { return }
        // Two soft edges together spread a little less than their sum, as blurs do.
        let softened = (current.feather * current.feather + CGFloat(amount) * CGFloat(amount)).squareRoot()
        setSelection(DocumentSelection(path: current.path, antialiased: current.antialiased,
                                       feather: min(250, softened)), name: "Feather Selection")
    }

    private func resizeSelection(by delta: CGFloat, name: String) {
        guard let document, let current = selection, canModifySelection, delta != 0, abs(delta) <= 500 else { return }
        // A band `|delta|` wide on each side of the outline, added or removed.
        let band = current.path.copy(strokingWithWidth: abs(delta) * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let result = delta > 0
            ? current.path.union(band, using: .winding)
                .intersection(CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil), using: .winding)
            : current.path.subtracting(band, using: .winding)
        setSelection(DocumentSelection(path: result, antialiased: current.antialiased, feather: current.feather), name: name)
    }

    func selectAll() {
        guard let document else { return }
        setSelection(DocumentSelection(path: CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)), name: "Select All")
    }

    func deselect() {
        guard selection != nil else { return }
        setSelection(nil, name: "Deselect")
    }

    func invertSelection() {
        guard let document, let current = selection else { return }
        let canvas = CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)
        setSelection(DocumentSelection(path: canvas.subtracting(current.path, using: .winding), antialiased: current.antialiased, feather: current.feather),
                     name: "Inverse")
    }
}
