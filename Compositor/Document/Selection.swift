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

extension CGPath {
    /// The outline without the hairlines Core Graphics leaves where edges should meet exactly but miss by a millionth of a
    /// pixel, as a box's edge clipped to the canvas meeting the selection's own. They select nothing, but the marching ants
    /// trace them: pieces a hair wide, spurs running out along an edge and straight back, and cut-outs drawn as a second
    /// outline over the first rather than merged into it. Straight edges go onto a 1/4096 px grid, so those that should
    /// meet do; split where another edge's corner lies on them; and every pair running between the same two points in
    /// opposite directions goes. Such a pair adds nothing to what's selected, so the fill stays as it was. What's left is
    /// linked back into outlines; curved pieces are kept as they are.
    nonisolated var withoutSlivers: CGPath {
        struct Point: Hashable, Comparable {
            let x: Int64, y: Int64
            static func < (a: Point, b: Point) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
        }
        struct Edge: Hashable { let from: Point, to: Point }
        let grid: CGFloat = 4096
        func onGrid(_ point: CGPoint) -> Point? {
            let x = (point.x * grid).rounded(), y = (point.y * grid).rounded()
            guard abs(x) < 1e15, abs(y) < 1e15 else { return nil }
            return Point(x: Int64(x), y: Int64(y))
        }

        // Straight pieces become edges; anything with a curve is kept whole.
        var edges: [Edge] = []
        let curved = CGMutablePath()
        var piece: [CGPathElement] = [], piecePoints: [CGPoint] = []
        var straightCount = 0, unusable = false
        func finishPiece() {
            defer { piece = []; piecePoints = [] }
            guard !piece.isEmpty else { return }
            if piece.contains(where: { $0.type == .addQuadCurveToPoint || $0.type == .addCurveToPoint }) {
                var at = 0
                for element in piece {
                    switch element.type {
                    case .moveToPoint: curved.move(to: piecePoints[at]); at += 1
                    case .addLineToPoint: curved.addLine(to: piecePoints[at]); at += 1
                    case .addQuadCurveToPoint: curved.addQuadCurve(to: piecePoints[at + 1], control: piecePoints[at]); at += 2
                    case .addCurveToPoint:
                        curved.addCurve(to: piecePoints[at + 2], control1: piecePoints[at], control2: piecePoints[at + 1]); at += 3
                    case .closeSubpath: curved.closeSubpath()
                    @unknown default: break
                    }
                }
                return
            }
            let corners = piecePoints.compactMap(onGrid)
            guard corners.count == piecePoints.count else { unusable = true; return }
            straightCount += corners.count
            // Closed, as a fill treats every piece.
            for (at, corner) in corners.enumerated() {
                let next = corners[(at + 1) % corners.count]
                if next != corner { edges.append(Edge(from: corner, to: next)) }
            }
        }
        applyWithBlock { pointer in
            let element = pointer.pointee
            let count = switch element.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            if element.type == .moveToPoint { finishPiece() }
            piece.append(element)
            piecePoints += (0..<count).map { element.points[$0] }
        }
        finishPiece()
        guard !unusable, straightCount > 0 else { return self }

        // Split each edge where a corner of another lies on it. Corners sorted by x, so each edge checks only those
        // within its own span.
        let corners = Array(Set(edges.flatMap { [$0.from, $0.to] })).sorted()
        var split: [Edge] = []
        split.reserveCapacity(edges.count)
        for edge in edges {
            let low = min(edge.from.x, edge.to.x), high = max(edge.from.x, edge.to.x)
            let dx = edge.to.x - edge.from.x, dy = edge.to.y - edge.from.y
            let length = dx * dx + dy * dy
            var start = 0, end = corners.count
            while start < end {
                let middle = (start + end) / 2
                if corners[middle].x < low { start = middle + 1 } else { end = middle }
            }
            var inside: [(along: Int64, point: Point)] = []
            while start < corners.count, corners[start].x <= high {
                let corner = corners[start]
                start += 1
                guard corner != edge.from, corner != edge.to,
                      corner.y >= min(edge.from.y, edge.to.y), corner.y <= max(edge.from.y, edge.to.y) else { continue }
                let rx = corner.x - edge.from.x, ry = corner.y - edge.from.y
                let along = rx * dx + ry * dy
                if dx * ry - dy * rx == 0, along > 0, along < length { inside.append((along, corner)) }
            }
            guard !inside.isEmpty else { split.append(edge); continue }
            var from = edge.from
            for stop in inside.sorted(by: { $0.along < $1.along }) {
                split.append(Edge(from: from, to: stop.point))
                from = stop.point
            }
            split.append(Edge(from: from, to: edge.to))
        }

        // Opposite pairs cancel.
        var remaining: [Edge: Int] = [:]
        var cancelled = 0
        for edge in split {
            let back = Edge(from: edge.to, to: edge.from)
            if let count = remaining[back], count > 0 {
                remaining[back] = count - 1
                cancelled += 1
            } else {
                remaining[edge, default: 0] += 1
            }
        }
        guard cancelled > 0 else { return self }

        // Every corner still has as many edges in as out, so following them always leads back to the start.
        var leaving: [Point: [Point]] = [:]
        for (edge, count) in remaining where count > 0 {
            leaving[edge.from, default: []] += Array(repeating: edge.to, count: count)
        }
        let path = CGMutablePath()
        path.addPath(curved)
        for start in leaving.keys.sorted() {
            while let first = leaving[start]?.popLast() {
                var loop = [start], at = first
                while at != start, let next = leaving[at]?.popLast() {
                    loop.append(at)
                    at = next
                }
                guard loop.count >= 3 else { continue }
                path.addLines(between: loop.map { CGPoint(x: CGFloat($0.x) / grid, y: CGFloat($0.y) / grid) })
                path.closeSubpath()
            }
        }
        return path
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

    /// The size the status bar shows, in whole pixels: the Marquee being drawn, else the box around the selection
    /// within the canvas. Nil with neither.
    var selectionSize: (width: Int, height: Int)? {
        if let draft = lassoDraft, draft.anchor != nil, draft.points.count == 4 {
            let xs = draft.points.map(\.x), ys = draft.points.map(\.y)
            return (Int((xs.max()! - xs.min()!).rounded()), Int((ys.max()! - ys.min()!).rounded()))
        }
        guard let document, let selection, !selection.isEmpty else { return nil }
        let box = selection.path.boundingBoxOfPath.intersection(CGRect(origin: .zero, size: document.size)).integral
        return box.isEmpty ? nil : (Int(box.width), Int(box.height))
    }

    /// Off hides the marching ants of the current selection only.
    var showsSelectionEdges: Bool {
        get { selection == nil || hiddenSelectionEdges != selection }
        set { hiddenSelectionEdges = newValue ? nil : selection }
    }

    /// View › Show Extras (⌘H, outside the Move tool): the selection's edges and the guides together, to see the
    /// picture alone. On only while both are showing, so ⌘H hides whatever is showing and, pressed again, brings it
    /// all back. Guides turned off with ⌘; stay off.
    var showsExtras: Bool {
        get { showsSelectionEdges && !extrasHideGuides }
        set {
            showsSelectionEdges = newValue
            extrasHideGuides = !newValue
        }
    }

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
        // Click-selection tools never draw a draft outline.
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

    /// Moves the Marquee being drawn without resizing it, its starting corner now at `anchor` (Space held mid-drag).
    func moveMarqueeAnchor(to anchor: CGPoint) {
        guard lassoDraft?.anchor != nil, anchor.x.isFinite, anchor.y.isFinite else { return }
        lassoDraft?.anchor = anchor
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

    /// W picks the Magic tool; Tab switches its Wand and Object modes.
    func pressWandKey() {
        selectTool(.wand)
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
                       name: draft.kind == .freehand ? "Lasso" : draft.kind == .polygonal ? "Polygonal Lasso"
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
        setSelection(DocumentSelection(path: result.withoutSlivers, antialiased: selectionAntialiased), name: name)
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
        setSelection(DocumentSelection(path: result.withoutSlivers, antialiased: current.antialiased, feather: current.feather), name: name)
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
        let inverse = DocumentSelection(path: canvas.subtracting(current.path, using: .winding).withoutSlivers, antialiased: current.antialiased,
                                        feather: current.feather)
        // The inverse of everything is no selection at all, as in Photoshop — not an invisible empty one that
        // quietly stops every brush.
        setSelection(inverse.isEmpty ? nil : inverse, name: "Inverse")
    }
}
