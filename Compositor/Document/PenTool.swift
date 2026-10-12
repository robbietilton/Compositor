import AppKit

nonisolated enum PenMode: String, CaseIterable, Codable, Sendable {
    case shape = "Shape"
    case line = "Line"
}

/// One anchor in a Pen path. Points are fractions of the layer's box once the path is committed; a draft keeps
/// them in document pixels. A click leaves both handles on the anchor for a corner, and a drag pulls out a smooth
/// pair of handles.
nonisolated struct VectorPathNode: Codable, Equatable, Sendable {
    var anchor: CGPoint
    var inHandle: CGPoint
    var outHandle: CGPoint

    init(anchor: CGPoint, inHandle: CGPoint? = nil, outHandle: CGPoint? = nil) {
        self.anchor = anchor
        self.inHandle = inHandle ?? anchor
        self.outHandle = outHandle ?? anchor
    }

    nonisolated var isFinite: Bool {
        [anchor, inHandle, outHandle].allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

/// The editable vector information saved with a Pen layer. The PNG beside it remains the display fallback for
/// older builds and becomes authoritative if a pixel edit rasterizes the layer.
nonisolated struct LayerVectorPathStyle: Codable, Equatable, Sendable {
    var mode: PenMode
    var nodes: [VectorPathNode]
    var closed: Bool
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Used by Line paths. Shape paths are filled and have no stroke.
    var lineWidth: CGFloat

    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }
    var isValid: Bool {
        let required = mode == .shape ? 3 : 2
        return nodes.count >= required && nodes.count <= 10_000 && (mode != .shape || closed)
            && nodes.allSatisfy { node in
                node.isFinite && [node.anchor, node.inHandle, node.outHandle].allSatisfy {
                    (-0.000_001...1.000_001).contains($0.x) && (-0.000_001...1.000_001).contains($0.y)
                }
            }
            && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && lineWidth.isFinite && (1...5_000).contains(lineWidth)
    }

    /// The path in the supplied local pixel box.
    func path(in rect: CGRect) -> CGPath {
        Self.path(nodes: nodes.map { node in
            VectorPathNode(anchor: point(node.anchor, in: rect),
                           inHandle: point(node.inHandle, in: rect),
                           outHandle: point(node.outHandle, in: rect))
        }, closed: closed)
    }

    private func point(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    static func path(nodes: [VectorPathNode], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = nodes.first else { return path }
        path.move(to: first.anchor)
        for index in nodes.indices.dropFirst() {
            let previous = nodes[index - 1], node = nodes[index]
            if previous.outHandle == previous.anchor && node.inHandle == node.anchor {
                path.addLine(to: node.anchor)
            } else {
                path.addCurve(to: node.anchor, control1: previous.outHandle, control2: node.inHandle)
            }
        }
        if closed, let last = nodes.last {
            if last.outHandle == last.anchor && first.inHandle == first.anchor {
                path.closeSubpath()
            } else {
                path.addCurve(to: first.anchor, control1: last.outHandle, control2: first.inHandle)
                path.closeSubpath()
            }
        }
        return path
    }
}

nonisolated struct LayerVectorPath: Equatable, @unchecked Sendable {
    var style: LayerVectorPathStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerVectorPathStyle?, image: CGImage?) -> LayerVectorPath? {
        guard let style, style.isValid, let image else { return nil }
        return LayerVectorPath(style: style, image: image)
    }
}

extension ImageLayer {
    /// The Pen path this layer still represents. A pixel edit replaces the image and thereby rasterizes it.
    var liveVectorPath: LayerVectorPath? {
        guard let vectorPath, let image = asset?.image, image === vectorPath.image else { return nil }
        return vectorPath
    }
}

struct PenDraft: Equatable {
    let mode: PenMode
    let color: PaletteColor
    var lineWidth: CGFloat
    var nodes: [VectorPathNode]
    /// The rubber-band point shown before the next anchor is placed.
    var hoverPoint: CGPoint?
}

struct PenNodeSelection: Equatable {
    let layerID: UUID
    var index: Int
}

struct EditablePenLine {
    let index: Int
    let layer: ImageLayer
    let vector: LayerVectorPath
}

extension EditorSession {
    /// The selected live Pen line. Its saved nodes stay normalized to the layer, while editing maps them through the
    /// layer transform so a moved, scaled, flipped or rotated line can still be edited in place.
    var editablePenLine: EditablePenLine? {
        guard tool == .pen, penDraft == nil, canEditLayers, selectedLayerIDs.count == 1,
              let id = activeLayerID, let document,
              document.effectiveVisibleIDs.contains(id),
              let index = document.layers.firstIndex(where: { $0.id == id }),
              let vector = document.layers[index].liveVectorPath, vector.style.mode == .line else { return nil }
        return EditablePenLine(index: index, layer: document.layers[index], vector: vector)
    }

    var selectedPenNodeIndex: Int? {
        guard let line = editablePenLine, let selection = penNodeSelection,
              selection.layerID == line.layer.id, line.vector.style.nodes.indices.contains(selection.index) else { return nil }
        return selection.index
    }

    var currentPenLineWidth: Double {
        editablePenLine.map { Double($0.vector.style.lineWidth) } ?? penLineWidth
    }

    var canDeleteSelectedPenNode: Bool {
        selectedPenNodeIndex != nil && (editablePenLine?.vector.style.nodes.count ?? 0) > 2
    }

    /// The current draft takes precedence over the selected layer's saved path. Both are mapped into document
    /// pixels and closed only for the selection; a saved open path itself remains unchanged.
    private var penPathForSelection: CGPath? {
        guard tool == .pen else { return nil }
        if let draft = penDraft {
            guard draft.nodes.count >= 3, draft.nodes.allSatisfy(\.isFinite) else { return nil }
            let path = LayerVectorPathStyle.path(nodes: draft.nodes, closed: true)
            let bounds = path.boundingBoxOfPath
            return bounds.width > 0 && bounds.height > 0 ? path : nil
        }
        guard selectedLayerIDs.count == 1, let layer = activeLayer, let vector = layer.liveVectorPath,
              vector.style.nodes.count >= 3 else { return nil }
        let transform = layer.transform.unitToDocument
        let nodes = vector.style.nodes.map { node in
            VectorPathNode(anchor: node.anchor.applying(transform),
                           inHandle: node.inHandle.applying(transform),
                           outHandle: node.outHandle.applying(transform))
        }
        guard nodes.allSatisfy(\.isFinite) else { return nil }
        let path = LayerVectorPathStyle.path(nodes: nodes, closed: true)
        let bounds = path.boundingBoxOfPath
        return bounds.width > 0 && bounds.height > 0 ? path : nil
    }

    var canLoadPenPathAsSelection: Bool { canEditSelection && penPathForSelection != nil }

    /// Replaces the current selection with the area enclosed by the Pen path. A pending draft is consumed directly
    /// instead of becoming a colored layer; an existing saved path is only read and is not changed.
    @discardableResult
    func loadPenPathAsSelection() -> Bool {
        guard canEditSelection, let path = penPathForSelection else { return false }
        let consumesDraft = penDraft != nil
        applySelection(path, mode: .replace, name: "Load Path as Selection")
        if consumesDraft {
            penDraft = nil
            penNodeSelection = nil
        }
        return true
    }

    /// Selects an existing anchor, or splits the path at a click on one of its segments. The transaction stays open
    /// until mouse-up so inserting and immediately dragging the new anchor is one undo step.
    func beginPenLineNodeGesture(at point: CGPoint, tolerance: CGFloat) -> Int? {
        guard tolerance.isFinite, tolerance > 0, let line = editablePenLine else { return nil }
        let transform = line.layer.transform.unitToDocument
        let documentNodes = line.vector.style.nodes.map { node in
            VectorPathNode(anchor: node.anchor.applying(transform),
                           inHandle: node.inHandle.applying(transform),
                           outHandle: node.outHandle.applying(transform))
        }
        if let index = documentNodes.indices.min(by: {
            Self.penDistance(documentNodes[$0].anchor, point) < Self.penDistance(documentNodes[$1].anchor, point)
        }), Self.penDistance(documentNodes[index].anchor, point) <= tolerance {
            penNodeSelection = PenNodeSelection(layerID: line.layer.id, index: index)
            beginEdit("Move Pen Anchor")
            penNodeGestureEditing = true
            return index
        }
        guard let split = Self.closestPenSegment(to: point, nodes: documentNodes), split.distance <= tolerance else {
            penNodeSelection = nil
            return nil
        }
        beginEdit("Add Pen Anchor")
        penNodeGestureEditing = true
        var style = line.vector.style
        Self.splitPenSegment(before: split.index, at: split.t, nodes: &style.nodes)
        guard replaceActivePenLine(with: style, preview: true) else {
            penNodeGestureEditing = false
            endEdit()
            return nil
        }
        penNodeSelection = PenNodeSelection(layerID: line.layer.id, index: split.index)
        return split.index
    }

    /// Moves an anchor and its handles together. Reframing after each change lets it travel beyond the old layer box,
    /// gives a thicker stroke enough transparent padding and prevents it being clipped.
    func movePenLineNode(_ index: Int, to documentPoint: CGPoint) {
        guard penNodeGestureEditing, let line = editablePenLine,
              line.vector.style.nodes.indices.contains(index), documentPoint.x.isFinite, documentPoint.y.isFinite else { return }
        var style = line.vector.style
        var node = style.nodes[index]
        let proposed = documentPoint.applying(line.layer.transform.unitToDocument.inverted())
        guard proposed.x.isFinite, proposed.y.isFinite else { return }
        let dx = proposed.x - node.anchor.x, dy = proposed.y - node.anchor.y
        for key in [\VectorPathNode.anchor, \VectorPathNode.inHandle, \VectorPathNode.outHandle] {
            node[keyPath: key].x += dx
            node[keyPath: key].y += dy
        }
        style.nodes[index] = node
        _ = replaceActivePenLine(with: style, preview: true)
    }

    func endPenLineNodeGesture() {
        guard penNodeGestureEditing else { return }
        if let line = editablePenLine { _ = replaceActivePenLine(with: line.vector.style) }
        penNodeGestureEditing = false
        endEdit()
    }

    /// Delete belongs to the selected anchor while a live line is being edited. A two-anchor line cannot lose another
    /// point; the key is still consumed so it never unexpectedly deletes the whole layer instead.
    @discardableResult
    func deleteSelectedPenNode() -> Bool {
        guard let line = editablePenLine, let index = selectedPenNodeIndex else { return false }
        guard line.vector.style.nodes.count > 2 else { return true }
        beginEdit("Delete Pen Anchor")
        var style = line.vector.style
        style.nodes.remove(at: index)
        if replaceActivePenLine(with: style) {
            penNodeSelection = PenNodeSelection(layerID: line.layer.id, index: min(index, style.nodes.count - 1))
        }
        endEdit()
        return true
    }

    func beginPenLineWidthEdit() {
        guard !penLineWidthEditing, editablePenLine != nil else { return }
        beginEdit("Pen Line Width")
        penLineWidthEditing = true
    }

    func finishPenLineWidthEdit() {
        guard penLineWidthEditing else { return }
        if let line = editablePenLine { _ = replaceActivePenLine(with: line.vector.style) }
        penLineWidthEditing = false
        endEdit()
    }

    func setPenLineWidth(_ proposed: Double) {
        let width = proposed.isFinite ? min(5_000, max(1, proposed)) : 4
        penLineWidth = width
        if var draft = penDraft, draft.mode == .line {
            draft.lineWidth = CGFloat(width)
            penDraft = draft
            return
        }
        guard let line = editablePenLine, line.vector.style.lineWidth != CGFloat(width) else { return }
        let ownsTransaction = !penLineWidthEditing
        if ownsTransaction { beginEdit("Pen Line Width") }
        var style = line.vector.style
        style.lineWidth = CGFloat(width)
        _ = replaceActivePenLine(with: style, preview: penLineWidthEditing)
        if ownsTransaction { endEdit() }
    }

    /// Begins a new anchor, or closes the path when the pointer is close to its first anchor. Returns true when the
    /// path closed and committed, so the canvas does not treat the same gesture as a new point.
    @discardableResult
    func beginPenAnchor(at rawPoint: CGPoint, closeDistance: CGFloat, constrain: Bool) -> Bool {
        guard tool == .pen, canEditLayers, rawPoint.x.isFinite, rawPoint.y.isFinite else { return false }
        if let draft = penDraft, let first = draft.nodes.first,
           draft.nodes.count >= (draft.mode == .shape ? 3 : 2), hypot(rawPoint.x - first.anchor.x, rawPoint.y - first.anchor.y) <= closeDistance {
            return finishPen(closed: true)
        }
        var point = rawPoint
        if constrain, let anchor = penDraft?.nodes.last?.anchor { point = Self.penSnapped(point, around: anchor) }
        if penDraft == nil {
            penDraft = PenDraft(mode: penMode, color: foregroundColor, lineWidth: CGFloat(penLineWidth),
                                nodes: [], hoverPoint: nil)
        }
        penDraft?.nodes.append(VectorPathNode(anchor: point))
        penDraft?.hoverPoint = nil
        return false
    }

    /// Pulls symmetric direction handles out of the newest anchor. Shift constrains their angle to 45° steps.
    func dragPenHandle(to rawPoint: CGPoint, constrain: Bool) {
        guard var draft = penDraft, var node = draft.nodes.last,
              rawPoint.x.isFinite, rawPoint.y.isFinite else { return }
        let point = constrain ? Self.penSnapped(rawPoint, around: node.anchor) : rawPoint
        let delta = CGPoint(x: point.x - node.anchor.x, y: point.y - node.anchor.y)
        node.outHandle = point
        node.inHandle = CGPoint(x: node.anchor.x - delta.x, y: node.anchor.y - delta.y)
        draft.nodes[draft.nodes.count - 1] = node
        draft.hoverPoint = nil
        penDraft = draft
    }

    func movePenCursor(to rawPoint: CGPoint, constrain: Bool) {
        guard var draft = penDraft, rawPoint.x.isFinite, rawPoint.y.isFinite else { return }
        draft.hoverPoint = constrain && !draft.nodes.isEmpty
            ? Self.penSnapped(rawPoint, around: draft.nodes.last!.anchor) : rawPoint
        penDraft = draft
    }

    func clearPenCursor() {
        guard var draft = penDraft, draft.hoverPoint != nil else { return }
        draft.hoverPoint = nil
        penDraft = draft
    }

    func removeLastPenAnchor() {
        guard var draft = penDraft else { return }
        if !draft.nodes.isEmpty { draft.nodes.removeLast() }
        if draft.nodes.isEmpty { penDraft = nil }
        else { draft.hoverPoint = nil; penDraft = draft }
    }

    func cancelPen() {
        finishPenLineWidthEdit()
        endPenLineNodeGesture()
        penDraft = nil
        penNodeSelection = nil
    }

    /// Commits an open line, or a closed filled shape. Shape mode closes automatically on Return or double-click.
    @discardableResult
    func finishPen(closed: Bool = false) -> Bool {
        guard let draft = penDraft else { return false }
        let closes = closed || draft.mode == .shape
        guard draft.nodes.count >= (draft.mode == .shape ? 3 : 2) else { return false }
        let styleAndBox = Self.committedPenStyle(draft, closed: closes)
        guard let styleAndBox else {
            brushError = "That path is too large or contains invalid points."
            return false
        }
        do {
            let image = try Self.vectorPathImage(styleAndBox.style, size: styleAndBox.box.size)
            penDraft = nil
            let name = nextPenName(draft.mode)
            addPixelLayer(image, at: styleAndBox.box.origin, name: name,
                          editName: draft.mode == .shape ? "Pen Shape" : "Pen Line", dropsSelection: false,
                          vectorPath: LayerVectorPath(style: styleAndBox.style, image: image))
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    func nextPenName(_ mode: PenMode) -> String {
        let base = mode == .shape ? "Path" : "Pen Line"
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private nonisolated static func committedPenStyle(_ draft: PenDraft, closed: Bool)
        -> (style: LayerVectorPathStyle, box: CGRect)? {
        let points = draft.nodes.flatMap { [$0.anchor, $0.inHandle, $0.outHandle] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let padding = draft.mode == .line ? draft.lineWidth / 2 + 1 : 1
        let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -padding, dy: -padding).integral
        guard box.width >= 1, box.height >= 1,
              box.width <= CGFloat(DocumentLimits.maxSide), box.height <= CGFloat(DocumentLimits.maxSide),
              box.width * box.height <= CGFloat(maxShapePixels) else { return nil }
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        }
        let nodes = draft.nodes.map {
            VectorPathNode(anchor: unit($0.anchor), inHandle: unit($0.inHandle), outHandle: unit($0.outHandle))
        }
        let style = LayerVectorPathStyle(mode: draft.mode, nodes: nodes, closed: closed,
            red: draft.color.red, green: draft.color.green, blue: draft.color.blue, lineWidth: draft.lineWidth)
        return style.isValid ? (style, box) : nil
    }

    nonisolated static func vectorPathImage(_ style: LayerVectorPathStyle, size: CGSize,
                                            lineWidthScale: CGFloat = 1) throws -> CGImage {
        guard style.isValid, size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= CGFloat(DocumentLimits.maxSide), size.height <= CGFloat(DocumentLimits.maxSide),
              size.width * size.height <= CGFloat(maxShapePixels),
              lineWidthScale.isFinite, lineWidthScale > 0 else { throw ExportError.render }
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.addPath(style.path(in: CGRect(x: 0, y: 0, width: width, height: height)))
        let color = CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        if style.mode == .shape {
            context.setFillColor(color)
            context.fillPath(using: .winding)
        } else {
            context.setStrokeColor(color)
            context.setLineWidth(style.lineWidth * lineWidthScale)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    func redrawVectorPath(at index: Int) {
        guard let layer = document?.layers[index], let vector = layer.liveVectorPath, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded()))
        let height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height,
              width * height <= Self.maxShapePixels,
              let image = try? Self.vectorPathImage(vector.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].vectorPath = LayerVectorPath(style: vector.style, image: image)
    }

    /// A crisp, bounded preview while a live vector layer is being resized.
    func vectorTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil, let vector = layer.liveVectorPath else { return nil }
        let size = transform.size
        guard size.width >= 1, size.height >= 1,
              abs(size.width - CGFloat(vector.image.width)) >= 0.5 || abs(size.height - CGFloat(vector.image.height)) >= 0.5 else { return nil }
        let factor = min(1, 2048 / max(size.width, size.height))
        let drawn = CGSize(width: max(1, (size.width * factor).rounded()),
                           height: max(1, (size.height * factor).rounded()))
        if let cached = shapeTransformPreviewCache[layer.id], cached.size == drawn { return cached.image }
        guard let image = try? Self.vectorPathImage(vector.style, size: drawn, lineWidthScale: factor) else { return nil }
        shapeTransformPreviewCache[layer.id] = (drawn, image)
        return image
    }

    nonisolated static func penSnapped(_ point: CGPoint, around anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: anchor.x + cos(angle) * length, y: anchor.y + sin(angle) * length)
    }

    /// During a drag, keep the changing bitmap bounded. Its transform still covers the path's full document box, so
    /// the GPU scales this temporary raster into place; mouse-up replaces it once with the full-resolution result.
    private func replaceActivePenLine(with proposed: LayerVectorPathStyle, preview: Bool = false) -> Bool {
        guard proposed.mode == .line, proposed.nodes.count >= 2, let line = editablePenLine,
              let asset = line.layer.asset else { return false }
        let oldTransform = line.layer.transform
        let localNodes = proposed.nodes.map { node in
            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(x: value.x * oldTransform.size.width, y: value.y * oldTransform.size.height)
            }
            return VectorPathNode(anchor: point(node.anchor), inHandle: point(node.inHandle), outHandle: point(node.outHandle))
        }
        let draft = PenDraft(mode: .line, color: proposed.color, lineWidth: proposed.lineWidth,
                             nodes: localNodes, hoverPoint: nil)
        guard let committed = Self.committedPenStyle(draft, closed: false) else { return false }
        do {
            let factor = preview ? min(1, Self.maxInteractivePenSide / max(committed.box.width, committed.box.height)) : 1
            let drawn = CGSize(width: max(1, (committed.box.width * factor).rounded()),
                               height: max(1, (committed.box.height * factor).rounded()))
            let image = try Self.vectorPathImage(committed.style, size: drawn, lineWidthScale: factor)
            let thumbnail = preview ? asset.thumbnail : try PixelInvert.thumbnail(of: image)
            let centerUnit = CGPoint(x: committed.box.midX / oldTransform.size.width,
                                     y: committed.box.midY / oldTransform.size.height)
            let center = centerUnit.applying(oldTransform.unitToDocument)
            var transform = oldTransform
            transform.size = committed.box.size
            transform.origin = CGPoint(x: center.x - transform.size.width / 2,
                                       y: center.y - transform.size.height / 2)
            if let mask = line.layer.mask, mask.placement == nil {
                document?.layers[line.index].mask?.placement = line.layer.maskTransform
            }
            document?.layers[line.index].transform = transform
            document?.layers[line.index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
            document?.layers[line.index].vectorPath = LayerVectorPath(style: committed.style, image: image)
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    private nonisolated static func penDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    nonisolated static let maxInteractivePenSide: CGFloat = 2_048

    private nonisolated static func penLerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private nonisolated static func penCurve(_ first: VectorPathNode, _ second: VectorPathNode, _ t: CGFloat) -> CGPoint {
        let a = penLerp(first.anchor, first.outHandle, t)
        let b = penLerp(first.outHandle, second.inHandle, t)
        let c = penLerp(second.inHandle, second.anchor, t)
        return penLerp(penLerp(a, b, t), penLerp(b, c, t), t)
    }

    /// Index is the segment's second node, which is also where its new split node is inserted.
    private nonisolated static func closestPenSegment(to point: CGPoint, nodes: [VectorPathNode])
        -> (index: Int, t: CGFloat, distance: CGFloat)? {
        guard nodes.count >= 2 else { return nil }
        var best: (index: Int, t: CGFloat, distance: CGFloat)?
        let steps = 32
        for index in nodes.indices.dropFirst() {
            var start = penCurve(nodes[index - 1], nodes[index], 0)
            for step in 1...steps {
                let endT = CGFloat(step) / CGFloat(steps)
                let end = penCurve(nodes[index - 1], nodes[index], endT)
                let vx = end.x - start.x, vy = end.y - start.y
                let lengthSquared = vx * vx + vy * vy
                let projected = lengthSquared > 0
                    ? min(1, max(0, ((point.x - start.x) * vx + (point.y - start.y) * vy) / lengthSquared)) : 0
                let nearest = CGPoint(x: start.x + vx * projected, y: start.y + vy * projected)
                let distance = penDistance(nearest, point)
                let t = (CGFloat(step - 1) + projected) / CGFloat(steps)
                if best == nil || distance < best!.distance { best = (index, t, distance) }
                start = end
            }
        }
        return best
    }

    private nonisolated static func splitPenSegment(before index: Int, at t: CGFloat,
                                                     nodes: inout [VectorPathNode]) {
        guard index > 0, nodes.indices.contains(index) else { return }
        var first = nodes[index - 1], second = nodes[index]
        if first.outHandle == first.anchor && second.inHandle == second.anchor {
            nodes.insert(VectorPathNode(anchor: penLerp(first.anchor, second.anchor, t)), at: index)
            return
        }
        let a = penLerp(first.anchor, first.outHandle, t)
        let b = penLerp(first.outHandle, second.inHandle, t)
        let c = penLerp(second.inHandle, second.anchor, t)
        let d = penLerp(a, b, t), e = penLerp(b, c, t)
        let anchor = penLerp(d, e, t)
        first.outHandle = a
        second.inHandle = c
        nodes[index - 1] = first
        nodes[index] = second
        nodes.insert(VectorPathNode(anchor: anchor, inHandle: d, outHandle: e), at: index)
    }
}
