import AppKit

/// A document-space selection outline, clipped to the canvas. `nil` on the document
/// means no selection; a selection whose path is empty is an explicit empty selection,
/// which later edits must treat as "touch nothing", never as "touch everything".
nonisolated struct DocumentSelection: Equatable, @unchecked Sendable {
    let path: CGPath
    var antialiased = true
    var isEmpty: Bool { path.isEmpty || path.boundingBoxOfPath.isNull || path.boundingBoxOfPath.isEmpty }

    /// Grayscale coverage at document resolution (white = selected), top-left origin.
    func coverage(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(antialiased)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}

extension DocumentSelection {
    /// Coverage for just the selected region of the canvas, ready to clip edits.
    func clip(canvas size: CGSize) throws -> SelectionClip {
        let region = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard !isEmpty, !region.isNull, region.width >= 1, region.height >= 1 else { return SelectionClip(rect: .zero, coverage: nil) }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: region.size))
        context.translateBy(x: -region.minX, y: -region.minY)
        context.setShouldAntialias(antialiased)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        guard let image = context.makeImage() else { throw ExportError.render }
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

nonisolated enum LassoKind: String, CaseIterable, Sendable {
    case freehand = "Freehand"
    case polygonal = "Polygonal"
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
        lassoDraft?.mode ?? selectionMode(shift: shift, option: option)
    }

    /// What the options bar highlights: the same rule, using the tracked held keys.
    var displayedSelectionMode: SelectionMode { lassoDraft?.mode ?? heldSelectionMode ?? selectionModeChoice }

    func updateHeldSelectionKeys(shift: Bool, option: Bool) {
        let held: SelectionMode? = option ? .subtract : shift ? .add : nil
        if heldSelectionMode != held { heldSelectionMode = held }
    }

    func beginLasso(at point: CGPoint, mode: SelectionMode) {
        // The Magic Wand selects with a click; it never draws an outline.
        guard tool.isSelectionTool, tool != .wand, canEditSelection, selectionMoveOrigin == nil else { return }
        if tool == .marquee {
            let anchor = CGPoint(x: point.x.rounded(), y: point.y.rounded())
            lassoDraft = LassoDraft(points: [anchor], cursor: nil, mode: mode, kind: marqueeKind, anchor: anchor)
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

    func moveLassoCursor(to point: CGPoint?) { lassoDraft?.cursor = point }

    func removeLastLassoPoint() {
        guard var draft = lassoDraft else { return }
        draft.points.removeLast()
        lassoDraft = draft.points.isEmpty ? nil : draft
    }

    func cancelLasso() { lassoDraft = nil }

    /// The M key chooses the Marquee in whichever shape it was last set to (switched only in the tool bar). The
    /// shape stays as last set while this project is open.
    func pressMarqueeKey() {
        selectTool(.marquee)
    }

    func toggleMarqueeKind() {
        cancelLasso()
        marqueeKind = marqueeKind == .rectangle ? .ellipse : .rectangle
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

    /// Closes the outline and combines it with the current selection. A click that
    /// encloses nothing deselects in New mode, as in Photoshop.
    func finishLasso() {
        guard let draft = lassoDraft else { return }
        lassoDraft = nil
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
                       name: draft.kind == .freehand ? L10n.string("Lasso") : draft.kind == .polygonal ? L10n.string("Polygonal Lasso")
                           : draft.kind == .ellipse ? L10n.string("Elliptical Marquee") : L10n.string("Rectangular Marquee"))
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
        beginEdit(L10n.string("Move Selection"))
        selectionMoveOrigin = selection
        return true
    }

    /// Offsets from the drag's start, rounded to whole pixels so edges stay crisp. The
    /// outline is not re-clipped, so it can leave the canvas and come back intact.
    func moveSelection(by offset: CGSize) {
        guard let origin = selectionMoveOrigin else { return }
        var shift = CGAffineTransform(translationX: offset.width.rounded(), y: offset.height.rounded())
        guard let path = origin.path.copy(using: &shift) else { return }
        document?.selection = DocumentSelection(path: path, antialiased: origin.antialiased)
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

    /// Grows the outline by `amount` pixels with rounded corners (Photoshop's Expand), clipped to the canvas.
    func expandSelection(by amount: Int) { resizeSelection(by: CGFloat(amount), name: L10n.string("Expand Selection")) }

    /// Shrinks the outline by `amount` pixels, including away from the canvas edges.
    /// Contracting past the middle leaves an explicit empty selection.
    func contractSelection(by amount: Int) { resizeSelection(by: -CGFloat(amount), name: L10n.string("Contract Selection")) }

    private func resizeSelection(by delta: CGFloat, name: String) {
        guard let document, let current = selection, canModifySelection, delta != 0, abs(delta) <= 500 else { return }
        // A band `|delta|` wide on each side of the outline, added or removed.
        let band = current.path.copy(strokingWithWidth: abs(delta) * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let result = delta > 0
            ? current.path.union(band, using: .winding)
                .intersection(CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil), using: .winding)
            : current.path.subtracting(band, using: .winding)
        setSelection(DocumentSelection(path: result, antialiased: current.antialiased), name: name)
    }

    func selectAll() {
        guard let document else { return }
        setSelection(DocumentSelection(path: CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)), name: L10n.string("Select All"))
    }

    func deselect() {
        guard selection != nil else { return }
        setSelection(nil, name: L10n.string("Deselect"))
    }

    func invertSelection() {
        guard let document, let current = selection else { return }
        let canvas = CGPath(rect: CGRect(origin: .zero, size: document.size), transform: nil)
        setSelection(DocumentSelection(path: canvas.subtracting(current.path, using: .winding), antialiased: current.antialiased),
                     name: L10n.string("Inverse"))
    }
}
