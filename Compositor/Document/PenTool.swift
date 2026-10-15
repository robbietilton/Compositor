import AppKit
import CoreGraphics
import Foundation

nonisolated enum PenMode: String, CaseIterable, Codable, Sendable {
    case shape = "Shape"
    case line = "Line"
}

nonisolated enum PenAction: String, CaseIterable, Sendable {
    case draw = "Draw"
    case bend = "Bend"
    case cut = "Cut"
    case erase = "Erase"

    var statusText: String {
        switch self {
        case .draw:
            "Click points · Drag curves · Click the first point to close · Double-click or Return to finish open · Double-click an existing point to smooth · ⌘Return loads selection"
        case .bend:
            "Drag a path segment to bend it · ⌘Z undo · Tab changes path tool"
        case .cut:
            "Click a path segment to cut it · Closed paths open; open paths split into separate pieces · ⌘Z undo"
        case .erase:
            "Drag the circular eraser across the selected path · [ ] size · Right-drag size · Escape returns to Draw · ⌘Z undo"
        }
    }
}

nonisolated struct VectorPathNode: Codable, Equatable, Sendable {
    var anchor: CGPoint
    var inHandle: CGPoint
    var outHandle: CGPoint

    init(anchor: CGPoint, inHandle: CGPoint? = nil, outHandle: CGPoint? = nil) {
        self.anchor = anchor
        self.inHandle = inHandle ?? anchor
        self.outHandle = outHandle ?? anchor
    }

    var isFinite: Bool {
        anchor.x.isFinite && anchor.y.isFinite &&
            inHandle.x.isFinite && inHandle.y.isFinite &&
            outHandle.x.isFinite && outHandle.y.isFinite
    }
}

nonisolated enum PenHandle: Equatable, Sendable {
    case incoming
    case outgoing
}

nonisolated struct LayerVectorPathFill: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite &&
            (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue)
    }
}

nonisolated struct LayerVectorPathBrushStroke: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var diameter: Double
    var hardness: Double
    var opacity: Double

    var isValid: Bool {
        red.isFinite && green.isFinite && blue.isFinite &&
            (0...1).contains(red) && (0...1).contains(green) && (0...1).contains(blue) &&
            diameter.isFinite && (1...2_100).contains(diameter) &&
            hardness.isFinite && (0...1).contains(hardness) &&
            opacity.isFinite && (0.01...1).contains(opacity)
    }
}

nonisolated struct LayerVectorPathEraseStroke: Codable, Equatable, Sendable {
    /// Unit-layer points. Separate diameters preserve a round document-space tip through nonuniform transforms.
    var points: [CGPoint]
    var diameterX: Double
    var diameterY: Double

    var isValid: Bool {
        !points.isEmpty && points.count <= 10_000 && points.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000
        } && diameterX.isFinite && diameterY.isFinite &&
            (0.000_001...5_000).contains(diameterX) && (0.000_001...5_000).contains(diameterY)
    }
}

nonisolated struct LayerVectorPathStyle: Codable, Equatable, Sendable {
    var mode: PenMode
    var red: Double
    var green: Double
    var blue: Double
    var lineWidth: Double
    var nodes: [VectorPathNode]
    var closed: Bool
    /// Node indexes that begin another disconnected subpath in this vector layer. Erasing can create several
    /// editable pieces without turning one object into several layers; older projects omit this field.
    var subpathStarts: [Int]? = nil
    var fill: LayerVectorPathFill? = nil
    var brushStroke: LayerVectorPathBrushStroke? = nil
    var eraseStrokes: [LayerVectorPathEraseStroke]? = nil

    var isValid: Bool {
        let starts = subpathStarts ?? []
        let ranges = penSubpathRanges(nodeCount: nodes.count, starts: starts)
        let enoughNodes = closed ? starts.isEmpty && nodes.count >= 3 : ranges.allSatisfy { $0.count >= 2 }
        guard enoughNodes, !ranges.isEmpty,
              starts == starts.sorted(), Set(starts).count == starts.count,
              (mode == .shape && closed) || (mode == .line && !closed),
              nodes.count <= 10_000,
              lineWidth.isFinite,
              (1...5_000).contains(lineWidth),
              red.isFinite, green.isFinite, blue.isFinite,
              (0...1).contains(red), (0...1).contains(green), (0...1).contains(blue),
              fill?.isValid != false, brushStroke?.isValid != false,
              (eraseStrokes?.count ?? 0) <= 1_000,
              eraseStrokes?.allSatisfy(\.isValid) != false,
              (eraseStrokes?.reduce(0, { $0 + $1.points.count }) ?? 0) <= 100_000
        else { return false }
        return nodes.allSatisfy { node in
            node.isFinite &&
                (0...1).contains(node.anchor.x) && (0...1).contains(node.anchor.y) &&
                (0...1).contains(node.inHandle.x) && (0...1).contains(node.inHandle.y) &&
                (0...1).contains(node.outHandle.x) && (0...1).contains(node.outHandle.y)
        }
    }

    func nodes(in size: CGSize) -> [VectorPathNode] {
        nodes.map { node in
            VectorPathNode(
                anchor: CGPoint(x: node.anchor.x * size.width, y: node.anchor.y * size.height),
                inHandle: CGPoint(x: node.inHandle.x * size.width, y: node.inHandle.y * size.height),
                outHandle: CGPoint(x: node.outHandle.x * size.width, y: node.outHandle.y * size.height)
            )
        }
    }

    static func path(nodes: [VectorPathNode], closed: Bool, subpathStarts: [Int]? = nil) -> CGPath {
        let path = CGMutablePath()
        for range in penSubpathRanges(nodeCount: nodes.count, starts: subpathStarts ?? []) where !range.isEmpty {
            let first = nodes[range.lowerBound]
            path.move(to: first.anchor)
            for index in range.dropFirst() {
                let previous = nodes[index - 1]
                let node = nodes[index]
                path.addCurve(to: node.anchor, control1: previous.outHandle, control2: node.inHandle)
            }
            if closed, let lastIndex = range.indices.last {
                let last = nodes[lastIndex]
                path.addCurve(to: first.anchor, control1: last.outHandle, control2: first.inHandle)
                path.closeSubpath()
            }
        }
        return path
    }
}

nonisolated struct LayerVectorPath: Equatable, @unchecked Sendable {
    var style: LayerVectorPathStyle
    var image: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.style == rhs.style && lhs.image === rhs.image
    }

    static func loaded(style: LayerVectorPathStyle, image: CGImage) -> LayerVectorPath? {
        guard style.isValid else { return nil }
        return LayerVectorPath(style: style, image: image)
    }
}

nonisolated struct PenDraft {
    var mode: PenMode
    var color: PaletteColor
    var lineWidth: Double
    var nodes: [VectorPathNode]
    var hoverPoint: CGPoint?
    var subpathStarts: [Int]? = nil
    var fill: LayerVectorPathFill? = nil
    var brushStroke: LayerVectorPathBrushStroke? = nil
    var eraseStrokes: [LayerVectorPathEraseStroke]? = nil
}

nonisolated struct PenClosureUndo {
    let layerID: UUID
    let draft: PenDraft
}

nonisolated struct PenBendGesture: Sendable {
    let segmentIndex: Int
    let t: CGFloat
    var lastPoint: CGPoint
}

nonisolated struct PenEraseGesture: Sendable {
    let layerID: UUID
    var lastPoint: CGPoint
    var changed = false
    var fillStrokeIndex: Int?
}

extension ImageLayer {
    var liveVectorPath: LayerVectorPath? {
        guard let vectorPath,
              asset?.image === vectorPath.image,
              shape == nil,
              text == nil
        else { return nil }
        return vectorPath
    }
}

extension EditorSession {
    var canLoadPenPathSelection: Bool {
        canEditSelection && penSelectionPath() != nil
    }

    var canFillPenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: true, requiresArea: true) != nil
    }

    var canStrokePenPath: Bool {
        canEditLayers && penDocumentPath(closeOpenPath: false, requiresArea: false) != nil
    }

    func cyclePenAction() {
        let actions = PenAction.allCases
        let index = actions.firstIndex(of: penAction) ?? 0
        selectPenAction(actions[(index + 1) % actions.count])
    }

    func selectPenAction(_ action: PenAction) {
        if action != .draw { resolvePenDraft() }
        penAction = action
    }

    /// Leaving Draw keeps a usable open path instead of silently losing it. A lone point cannot form a path.
    func resolvePenDraft() {
        guard let draft = penDraft else { return }
        // A path that cannot be committed (too large for a layer) is dropped rather than left blocking the session.
        if draft.nodes.count < (draft.mode == .shape ? 3 : 2) || !finishPen() { cancelPen() }
    }

    /// Converts the path being drawn, or the active vector path, to a selection without filling pixels.
    /// Open paths are joined from their last point back to their first to define the selected area.
    func loadPenPathSelection(mode: SelectionMode = .replace) {
        guard canEditSelection, let path = penSelectionPath() else { NSSound.beep(); return }
        beginEdit("Load Path Selection")
        defer { endEdit() }
        if penDraft != nil, !finishPen() { return }
        applySelection(path, mode: mode, name: "Load Path Selection")
        if let sourceLayerID = activeLayerID,
           let index = document?.layers.firstIndex(where: { $0.id == sourceLayerID }) {
            // Older projects stored a painted preview behind the vector nodes. Replace it with the transparent
            // path backing so loading a selection never leaves a fill or stroke over the marching ants.
            redrawVectorPath(at: index)
        }
    }

    /// Adds or updates the live fill on the editable path. Filling an open path joins its endpoints visually without
    /// closing the editable path, so its original geometry is still available for a brush stroke or selection.
    func fillPenPathWithForeground() {
        guard canFillPenPath else { NSSound.beep(); return }
        let hadDraft = penDraft != nil
        finishOpacityEdit()
        beginEdit("Fill Path")
        defer { endEdit() }
        if hadDraft, !finishPen() { return }
        guard var style = activeLayer?.liveVectorPath?.style else { return }
        style.red = Double(foregroundColor.red)
        style.green = Double(foregroundColor.green)
        style.blue = Double(foregroundColor.blue)
        style.fill = LayerVectorPathFill(red: style.red, green: style.green, blue: style.blue)
        replaceActivePenPath(with: style, preview: false)
    }

    /// Adds or updates a live brush stroke on the editable path. Its current brush color, size, hardness and opacity
    /// are retained so moving a node can redraw the same stroke without losing the path.
    func strokePenPathWithBrush() {
        guard canStrokePenPath else { NSSound.beep(); return }
        let hadDraft = penDraft != nil
        finishOpacityEdit()
        beginEdit("Stroke Path")
        defer { endEdit() }
        if hadDraft, !finishPen() { return }
        guard var style = activeLayer?.liveVectorPath?.style else { return }
        style.red = Double(foregroundColor.red)
        style.green = Double(foregroundColor.green)
        style.blue = Double(foregroundColor.blue)
        style.lineWidth = Double(brushSettings.diameter)
        style.brushStroke = LayerVectorPathBrushStroke(
            red: style.red,
            green: style.green,
            blue: style.blue,
            diameter: Double(brushSettings.diameter),
            hardness: Double(brushSettings.hardness),
            opacity: Double(brushSettings.opacity)
        )
        replaceActivePenPath(with: style, preview: false)
    }

    @discardableResult
    func beginPenAnchor(at point: CGPoint, closeDistance: CGFloat, constrain: Bool) -> Bool {
        guard tool == .pen, canEditLayers else { return false }
        if var draft = penDraft,
           draft.nodes.count >= 3,
           hypot(point.x - draft.nodes[0].anchor.x, point.y - draft.nodes[0].anchor.y) <= closeDistance {
            var openDraft = draft
            openDraft.hoverPoint = nil
            draft.mode = .shape
            penDraft = draft
            guard finishPen(), let layerID = activeLayerID else {
                // Closing was refused (for example, the path is too large). Keep drawing the open path.
                if penDraft != nil { penDraft = openDraft }
                return false
            }
            penClosureUndo = PenClosureUndo(layerID: layerID, draft: openDraft)
            return true
        }

        var anchor = point
        if constrain, let previous = penDraft?.nodes.last?.anchor {
            anchor = constrainedPenPoint(anchor, from: previous)
        }
        if penDraft == nil {
            penClosureUndo = nil
            selectedPenNodeIndex = nil
            selectedPenHandle = nil
            penDraft = PenDraft(
                mode: .line,
                color: foregroundColor,
                lineWidth: 4,
                nodes: [],
                hoverPoint: nil
            )
        }
        penDraft?.nodes.append(VectorPathNode(anchor: anchor))
        penDraft?.hoverPoint = nil
        return false
    }

    func dragPenHandle(to point: CGPoint, constrain: Bool) {
        guard var draft = penDraft, var node = draft.nodes.last else { return }
        var outHandle = point
        if constrain {
            outHandle = constrainedPenPoint(outHandle, from: node.anchor)
        }
        node.outHandle = outHandle
        node.inHandle = CGPoint(
            x: node.anchor.x * 2 - outHandle.x,
            y: node.anchor.y * 2 - outHandle.y
        )
        draft.nodes[draft.nodes.count - 1] = node
        penDraft = draft
    }

    func movePenCursor(to point: CGPoint?) {
        penDraft?.hoverPoint = point
    }

    func removeLastPenAnchor() {
        guard var draft = penDraft else { return }
        if !draft.nodes.isEmpty { draft.nodes.removeLast() }
        penDraft = draft.nodes.isEmpty ? nil : draft
    }

    func cancelPen() {
        penDraft = nil
        selectedPenNodeIndex = nil
        selectedPenHandle = nil
    }

    @discardableResult
    func finishPen() -> Bool {
        guard let draft = penDraft, let document else { return false }
        let closed = draft.mode == .shape
        guard let committed = committedPenStyle(draft, closed: closed),
              let image = PenBacking.image,
              let thumbnail = try? PixelInvert.thumbnail(of: image)
        else {
            NSSound.beep()
            return false
        }

        let vectorPath = LayerVectorPath(style: committed.style, image: image)
        let name = nextVectorPathName()
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: name),
                               origin: committed.box.origin)
        layer.name = name
        layer.transform.size = committed.box.size
        layer.vectorPath = vectorPath
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        finishOpacityEdit()
        beginEdit("Path")
        self.document?.layers.insert(layer, at: index)
        activeLayerID = layer.id
        endEdit()
        penDraft = nil
        selectedPenNodeIndex = nil
        selectedPenHandle = nil
        return true
    }

    func beginPenLineNodeGesture(at point: CGPoint, tolerance: CGFloat) -> Int? {
        guard tool == .pen, canEditLayers, penDraft == nil else { return nil }
        penLineGestureOrigin = nil
        penLineGestureChanged = false
        let paths = editablePenPaths()

        // Handles are drawn only for the active path, so hidden handles of other paths never capture a click.
        if let active = paths.first(where: { $0.0.id == activeLayerID }),
           let hit = nearestPenHandle(to: point, in: active.2, tolerance: tolerance) {
            selectedPenNodeIndex = hit.nodeIndex
            selectedPenHandle = hit.handle
            penLineGestureHandle = hit.handle
            beginEdit("Move Path Handle")
            penLineGestureActive = true
            return hit.nodeIndex
        }

        for (layer, vectorPath, documentNodes) in paths {
            if let nodeIndex = nearestPenNode(to: point, in: documentNodes, tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                selectedPenNodeIndex = nodeIndex
                selectedPenHandle = nil
                penLineGestureHandle = nil
                beginEdit("Move Path Point")
                penLineGestureActive = true
                return nodeIndex
            }

            if let hit = nearestPenSegment(to: point, in: documentNodes,
                                           closed: vectorPath.style.closed,
                                           subpathStarts: vectorPath.style.subpathStarts,
                                           tolerance: tolerance) {
                selectLayer(layer.id)
                guard activeLayerID == layer.id else { return nil }
                beginEdit("Add Path Point")
                penLineGestureActive = true
                penLineGestureHandle = nil
                var proposed = vectorPath.style
                let split = splitPenSegment(nodes: proposed.nodes,
                                            subpathStarts: proposed.subpathStarts,
                                            segmentIndex: hit.segmentIndex, t: hit.t,
                                            closed: proposed.closed)
                proposed.nodes = split.nodes
                proposed.subpathStarts = split.subpathStarts
                selectedPenNodeIndex = split.insertedIndex
                selectedPenHandle = nil
                replaceActivePenPath(with: proposed, preview: true)
                penLineGestureChanged = true
                return selectedPenNodeIndex
            }
        }
        return nil
    }

    /// Converts a corner anchor to a smooth point. Its handles follow the chord between the neighboring anchors,
    /// with independent lengths on each side; later handle drags keep them collinear unless Option breaks them.
    @discardableResult
    func smoothPenNode(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, canEditLayers, penDraft == nil else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            let transform = layer.transform.unitToDocument
            guard let index = nearestPenNode(to: point, in: nodes, tolerance: tolerance) else { continue }
            guard let range = penSubpathRanges(nodeCount: nodes.count,
                                               starts: vectorPath.style.subpathStarts ?? [])
                .first(where: { $0.contains(index) }),
                  vectorPath.style.closed || (index > range.lowerBound && index < range.upperBound - 1)
            else { return false }
            let previous = nodes[index == range.lowerBound ? range.upperBound - 1 : index - 1].anchor
            let anchor = nodes[index].anchor
            let next = nodes[index == range.upperBound - 1 ? range.lowerBound : index + 1].anchor
            var dx = next.x - previous.x
            var dy = next.y - previous.y
            var length = hypot(dx, dy)
            if length <= 0 {
                dx = next.x - anchor.x
                dy = next.y - anchor.y
                length = hypot(dx, dy)
            }
            guard length > 0 else { return false }
            dx /= length
            dy /= length
            let incomingLength = hypot(anchor.x - previous.x, anchor.y - previous.y) / 3
            let outgoingLength = hypot(next.x - anchor.x, next.y - anchor.y) / 3
            let incoming = CGPoint(x: anchor.x - dx * incomingLength,
                                   y: anchor.y - dy * incomingLength)
            let outgoing = CGPoint(x: anchor.x + dx * outgoingLength,
                                   y: anchor.y + dy * outgoingLength)
            let inverse = transform.inverted()
            let unitIncoming = incoming.applying(inverse)
            let unitOutgoing = outgoing.applying(inverse)
            guard unitIncoming.x.isFinite, unitIncoming.y.isFinite,
                  unitOutgoing.x.isFinite, unitOutgoing.y.isFinite else { return false }

            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            beginEdit("Smooth Path Point")
            var proposed = vectorPath.style
            proposed.nodes[index].inHandle = unitIncoming
            proposed.nodes[index].outHandle = unitOutgoing
            selectedPenNodeIndex = index
            selectedPenHandle = nil
            replaceActivePenPath(with: proposed, preview: false)
            endEdit()
            return true
        }
        return false
    }

    @discardableResult
    func beginPenBendGesture(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, penAction == .bend, canEditLayers, penDraft == nil else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            guard let hit = nearestPenSegment(to: point, in: nodes,
                                              closed: vectorPath.style.closed,
                                              subpathStarts: vectorPath.style.subpathStarts,
                                              tolerance: tolerance) else { continue }
            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            beginEdit("Bend Path")
            penLineGestureActive = true
            penLineGestureHandle = nil
            penLineGestureChanged = false
            penBendGesture = PenBendGesture(segmentIndex: hit.segmentIndex,
                                            t: min(0.95, max(0.05, hit.t)), lastPoint: point)
            selectedPenNodeIndex = nil
            selectedPenHandle = nil
            return true
        }
        return false
    }

    func dragPenBend(to point: CGPoint) {
        guard var gesture = penBendGesture,
              let layer = activeLayer,
              let vectorPath = layer.liveVectorPath else { return }
        let segments = penSegmentIndices(nodeCount: vectorPath.style.nodes.count,
                                         closed: vectorPath.style.closed,
                                         subpathStarts: vectorPath.style.subpathStarts)
        guard segments.contains(gesture.segmentIndex) else { return }
        let nextIndex = vectorPath.style.closed && gesture.segmentIndex == vectorPath.style.nodes.count - 1
            ? 0 : gesture.segmentIndex + 1
        let factor = max(0.01, 3 * gesture.t * (1 - gesture.t))
        let shift = CGSize(width: (point.x - gesture.lastPoint.x) / factor,
                           height: (point.y - gesture.lastPoint.y) / factor)
        guard shift.width.isFinite, shift.height.isFinite else { return }
        let transform = layer.transform.unitToDocument
        let inverse = transform.inverted()
        var proposed = vectorPath.style
        let outgoing = proposed.nodes[gesture.segmentIndex].outHandle.applying(transform)
        let incoming = proposed.nodes[nextIndex].inHandle.applying(transform)
        proposed.nodes[gesture.segmentIndex].outHandle = CGPoint(
            x: outgoing.x + shift.width, y: outgoing.y + shift.height
        ).applying(inverse)
        proposed.nodes[nextIndex].inHandle = CGPoint(
            x: incoming.x + shift.width, y: incoming.y + shift.height
        ).applying(inverse)
        replaceActivePenPath(with: proposed, preview: true)
        penLineGestureChanged = true
        gesture.lastPoint = point
        penBendGesture = gesture
    }

    @discardableResult
    func cutPenPath(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard tool == .pen, penAction == .cut, canEditLayers, penDraft == nil else { return false }
        for (layer, vectorPath, nodes) in editablePenPaths() {
            guard let hit = nearestPenSegment(to: point, in: nodes,
                                              closed: vectorPath.style.closed,
                                              subpathStarts: vectorPath.style.subpathStarts,
                                              tolerance: tolerance) else { continue }
            selectLayer(layer.id)
            guard activeLayerID == layer.id else { return false }
            let split = splitPenSegment(nodes: vectorPath.style.nodes,
                                        subpathStarts: vectorPath.style.subpathStarts,
                                        segmentIndex: hit.segmentIndex, t: hit.t,
                                        closed: vectorPath.style.closed)
            var proposed = vectorPath.style

            if !vectorPath.style.closed,
               let range = penSubpathRanges(nodeCount: vectorPath.style.nodes.count,
                                            starts: vectorPath.style.subpathStarts ?? [])
                .first(where: { $0.contains(hit.segmentIndex) }),
               (hit.segmentIndex == range.lowerBound && hit.t <= 0.001) ||
                (hit.segmentIndex == range.upperBound - 2 && hit.t >= 0.999) {
                // Cutting at an open end removes nothing and would leave a zero-length piece.
                return false
            }

            if vectorPath.style.closed {
                let cut = split.nodes[split.insertedIndex]
                var opened = Array(split.nodes[split.insertedIndex...])
                    + Array(split.nodes[..<split.insertedIndex]) + [cut]
                opened[0].inHandle = opened[0].anchor
                opened[opened.count - 1].outHandle = opened[opened.count - 1].anchor
                proposed.mode = .line
                proposed.closed = false
                proposed.nodes = opened
                proposed.subpathStarts = nil
                selectedPenNodeIndex = 0
            } else {
                var cutEnd = split.nodes[split.insertedIndex]
                cutEnd.outHandle = cutEnd.anchor
                var cutStart = split.nodes[split.insertedIndex]
                cutStart.inHandle = cutStart.anchor
                var opened = split.nodes
                opened[split.insertedIndex] = cutEnd
                opened.insert(cutStart, at: split.insertedIndex + 1)
                var starts = (split.subpathStarts ?? []).map {
                    $0 > split.insertedIndex ? $0 + 1 : $0
                }
                starts.append(split.insertedIndex + 1)
                proposed.nodes = opened
                proposed.subpathStarts = starts.sorted()
                selectedPenNodeIndex = split.insertedIndex + 1
            }
            guard proposed.isValid else { return false }
            beginEdit("Cut Path")
            selectedPenHandle = nil
            replaceActivePenPath(with: proposed, preview: false)
            endEdit()
            return true
        }
        return false
    }

    @discardableResult
    func beginPenErase(at point: CGPoint, diameter: CGFloat) -> Bool {
        guard tool == .pen, penAction == .erase, canEditLayers, penDraft == nil,
              point.x.isFinite, point.y.isFinite, diameter.isFinite, diameter > 0,
              let layerID = activeLayerID, activeLayer?.liveVectorPath != nil else { return false }
        finishOpacityEdit()
        beginEdit("Erase Path")
        penEraseGesture = PenEraseGesture(layerID: layerID, lastPoint: point)
        erasePenPath(from: point, to: point, radius: diameter / 2)
        return true
    }

    func dragPenErase(to point: CGPoint, diameter: CGFloat) {
        guard let gesture = penEraseGesture, point.x.isFinite, point.y.isFinite,
              diameter.isFinite, diameter > 0 else { return }
        erasePenPath(from: gesture.lastPoint, to: point, radius: diameter / 2)
        penEraseGesture?.lastPoint = point
    }

    func endPenErase() {
        guard let gesture = penEraseGesture else { return }
        penEraseGesture = nil
        if gesture.changed,
           let index = document?.layers.firstIndex(where: { $0.id == gesture.layerID }) {
            redrawVectorPath(at: index)
        }
        endEdit()
    }

    func dragPenLineNode(to documentPoint: CGPoint, constrain: Bool = false, breakHandles: Bool = false) {
        guard penLineGestureActive,
              let index = selectedPenNodeIndex,
              let layer = activeLayer,
              let vectorPath = layer.liveVectorPath,
              vectorPath.style.nodes.indices.contains(index)
        else { return }
        let transform = layer.transform.unitToDocument
        let inverse = transform.inverted()
        let anchor = vectorPath.style.nodes[index].anchor.applying(transform)
        if penLineGestureOrigin == nil { penLineGestureOrigin = anchor }
        // A handle snaps around its anchor; a moved point snaps around where the drag started.
        let origin = penLineGestureHandle == nil ? (penLineGestureOrigin ?? anchor) : anchor
        let target = constrain ? constrainedPenPoint(documentPoint, from: origin) : documentPoint
        let unit = target.applying(inverse)
        guard unit.x.isFinite, unit.y.isFinite else { return }
        var proposed = vectorPath.style

        if let handle = penLineGestureHandle {
            let oppositeKeyPath: WritableKeyPath<VectorPathNode, CGPoint>
            switch handle {
            case .incoming:
                proposed.nodes[index].inHandle = unit
                oppositeKeyPath = \.outHandle
            case .outgoing:
                proposed.nodes[index].outHandle = unit
                oppositeKeyPath = \.inHandle
            }
            if !breakHandles {
                let opposite = proposed.nodes[index][keyPath: oppositeKeyPath].applying(transform)
                let oppositeLength = hypot(opposite.x - anchor.x, opposite.y - anchor.y)
                let dx = target.x - anchor.x
                let dy = target.y - anchor.y
                let length = hypot(dx, dy)
                if length > 0, oppositeLength > 0 {
                    let mirrored = CGPoint(
                        x: anchor.x - dx / length * oppositeLength,
                        y: anchor.y - dy / length * oppositeLength
                    ).applying(inverse)
                    if mirrored.x.isFinite, mirrored.y.isFinite {
                        proposed.nodes[index][keyPath: oppositeKeyPath] = mirrored
                    }
                }
            }
            replaceActivePenPath(with: proposed, preview: true)
            penLineGestureChanged = true
            return
        }

        let delta = CGPoint(
            x: unit.x - proposed.nodes[index].anchor.x,
            y: unit.y - proposed.nodes[index].anchor.y
        )
        proposed.nodes[index].anchor.x += delta.x
        proposed.nodes[index].anchor.y += delta.y
        proposed.nodes[index].inHandle.x += delta.x
        proposed.nodes[index].inHandle.y += delta.y
        proposed.nodes[index].outHandle.x += delta.x
        proposed.nodes[index].outHandle.y += delta.y
        replaceActivePenPath(with: proposed, preview: true)
        penLineGestureChanged = true
    }

    func endPenLineNodeGesture() {
        guard penLineGestureActive else { return }
        penLineGestureActive = false
        penLineGestureHandle = nil
        penLineGestureOrigin = nil
        penBendGesture = nil
        // Only a gesture that changed the path re-renders it, so clicking a point to select it adds no undo step.
        if penLineGestureChanged, let id = activeLayerID,
           let index = document?.layers.firstIndex(where: { $0.id == id }) {
            redrawVectorPath(at: index)
        }
        penLineGestureChanged = false
        endEdit()
    }

    @discardableResult
    func removeSelectedPenNode() -> Bool {
        guard canEditLayers,
              !penLineGestureActive,
              let nodeIndex = selectedPenNodeIndex,
              let vectorPath = activeLayer?.liveVectorPath,
              vectorPath.style.nodes.indices.contains(nodeIndex),
              let range = penSubpathRanges(nodeCount: vectorPath.style.nodes.count,
                                           starts: vectorPath.style.subpathStarts ?? [])
                .first(where: { $0.contains(nodeIndex) }),
              range.count > (vectorPath.style.closed ? 3 : 2)
        else { return false }
        beginEdit("Delete Path Point")
        var proposed = vectorPath.style
        proposed.nodes.remove(at: nodeIndex)
        proposed.subpathStarts = proposed.subpathStarts?.map { $0 > nodeIndex ? $0 - 1 : $0 }
        selectedPenNodeIndex = min(nodeIndex, proposed.nodes.count - 1)
        selectedPenHandle = nil
        replaceActivePenPath(with: proposed, preview: false)
        endEdit()
        return true
    }

    /// Renders the path at full resolution and re-fits the layer around it. Re-fitting keeps a brush stroke's padding
    /// in document pixels after the layer is scaled, so a scaled-down stroke is not clipped at the layer's edge.
    func redrawVectorPath(at index: Int) {
        guard let document, document.layers.indices.contains(index),
              let style = document.layers[index].liveVectorPath?.style else { return }
        replacePenPath(at: index, with: style, preview: false, reportsErrors: false)
    }

    func vectorPathTransformPreview(for layer: ImageLayer, transform: LayerTransform) -> CGImage? {
        guard transformEdit != nil,
              let vectorPath = layer.liveVectorPath,
              vectorPath.style.fill != nil || vectorPath.style.brushStroke != nil,
              abs(transform.size.width - CGFloat(vectorPath.image.width)) >= 0.5 ||
                abs(transform.size.height - CGFloat(vectorPath.image.height)) >= 0.5
        else { return nil }
        let scale = min(1, 2_048 / max(max(transform.size.width, transform.size.height), 1))
        return vectorPathImage(
            style: vectorPath.style,
            size: CGSize(width: max(1, transform.size.width * scale),
                         height: max(1, transform.size.height * scale)),
            appearanceScale: scale
        )
    }

    private func replaceActivePenPath(with proposed: LayerVectorPathStyle, preview: Bool) {
        guard let id = activeLayerID,
              let index = document?.layers.firstIndex(where: { $0.id == id })
        else { return }
        replacePenPath(at: index, with: proposed, preview: preview, reportsErrors: true)
    }

    private func replacePenPath(at index: Int, with proposed: LayerVectorPathStyle, preview: Bool,
                                reportsErrors: Bool) {
        guard let document,
              document.layers.indices.contains(index),
              document.layers[index].liveVectorPath != nil,
              let oldAsset = document.layers[index].asset
        else { return }
        let oldTransform = document.layers[index].transform
        let localNodes = proposed.nodes(in: oldTransform.size)
        let draft = PenDraft(
            mode: proposed.mode,
            color: PaletteColor(red: CGFloat(proposed.red), green: CGFloat(proposed.green), blue: CGFloat(proposed.blue)),
            lineWidth: proposed.lineWidth,
            nodes: localNodes,
            hoverPoint: nil,
            subpathStarts: proposed.subpathStarts,
            fill: proposed.fill,
            brushStroke: proposed.brushStroke,
            eraseStrokes: proposed.eraseStrokes?.map { stroke in
                LayerVectorPathEraseStroke(
                    points: stroke.points.map {
                        CGPoint(x: $0.x * oldTransform.size.width, y: $0.y * oldTransform.size.height)
                    },
                    diameterX: stroke.diameterX * oldTransform.size.width,
                    diameterY: stroke.diameterY * oldTransform.size.height
                )
            }
        )
        guard let committed = committedPenStyle(draft, closed: proposed.closed) else { return }
        let fullSize = committed.box.size
        let painted = committed.style.fill != nil || committed.style.brushStroke != nil
        let pixelCount = painted ? Int(ceil(fullSize.width)) * Int(ceil(fullSize.height)) : 1
        let used = document.layers.indices.filter { $0 != index }.reduce(0) {
            $0 + (document.layers[$1].asset.map { $0.image.width * $0.image.height } ?? 0)
        }
        guard used + pixelCount <= DocumentLimits.documentPixelBudget else {
            if reportsErrors { brushError = ProjectError.tooLarge.localizedDescription }
            return
        }
        let scale = preview && painted ? min(1, 2_048 / max(max(fullSize.width, fullSize.height), 1)) : 1
        let imageSize = CGSize(width: max(1, fullSize.width * scale), height: max(1, fullSize.height * scale))
        guard let image = vectorPathImage(style: committed.style, size: imageSize, appearanceScale: scale) else {
            if reportsErrors { brushError = BrushStrokeError.pathTooComplex.localizedDescription }
            return
        }

        let centerUnit = CGPoint(
            x: committed.box.midX / max(oldTransform.size.width, 1),
            y: committed.box.midY / max(oldTransform.size.height, 1)
        )
        let center = centerUnit.applying(oldTransform.unitToDocument)
        var transform = oldTransform
        transform.size = fullSize
        transform.origin = CGPoint(x: center.x - fullSize.width / 2, y: center.y - fullSize.height / 2)
        let thumbnail = preview ? oldAsset.thumbnail : ((try? PixelInvert.thumbnail(of: image)) ?? oldAsset.thumbnail)
        self.document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: oldAsset.name)
        self.document?.layers[index].vectorPath = LayerVectorPath(style: committed.style, image: image)
        self.document?.layers[index].transform = transform
        if let mask = document.layers[index].mask, mask.placement == nil {
            self.document?.layers[index].mask?.placement = oldTransform
        }
    }

    private func penDocumentGeometry(closeOpenPath: Bool) ->
        (nodes: [VectorPathNode], closed: Bool, subpathStarts: [Int]?)? {
        if let draft = penDraft {
            guard draft.nodes.count >= (draft.mode == .shape ? 3 : 2),
                  draft.nodes.allSatisfy(\.isFinite)
            else { return nil }
            return (draft.nodes, closeOpenPath || draft.mode == .shape, draft.subpathStarts)
        }
        guard let layer = activeLayer, let vectorPath = layer.liveVectorPath else { return nil }
        let nodes = vectorPath.style.nodes(in: layer.transform.size).map { node in
            VectorPathNode(
                anchor: penDocumentPoint(node.anchor, transform: layer.transform),
                inHandle: penDocumentPoint(node.inHandle, transform: layer.transform),
                outHandle: penDocumentPoint(node.outHandle, transform: layer.transform)
            )
        }
        return (nodes, closeOpenPath || vectorPath.style.closed, vectorPath.style.subpathStarts)
    }

    private func penDocumentPath(closeOpenPath: Bool, requiresArea: Bool) -> CGPath? {
        guard let geometry = penDocumentGeometry(closeOpenPath: closeOpenPath) else { return nil }
        let path = LayerVectorPathStyle.path(nodes: geometry.nodes, closed: geometry.closed,
                                             subpathStarts: geometry.subpathStarts)
        let bounds = path.boundingBoxOfPath
        if bounds.isNull || (requiresArea ? bounds.width <= 0 || bounds.height <= 0 : bounds.width <= 0 && bounds.height <= 0) {
            return nil
        }
        return path
    }

    private func penSelectionPath() -> CGPath? {
        penDocumentPath(closeOpenPath: true, requiresArea: true)
    }

    private func committedPenStyle(_ draft: PenDraft, closed: Bool) -> (style: LayerVectorPathStyle, box: CGRect)? {
        guard draft.nodes.count >= (closed ? 3 : 2),
              draft.nodes.allSatisfy(\.isFinite),
              draft.lineWidth.isFinite
        else { return nil }
        let points = draft.nodes.flatMap { [$0.anchor, $0.inHandle, $0.outHandle] }
        guard let first = points.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        let padding = max(1, CGFloat(draft.brushStroke?.diameter ?? 0) / 2 + (draft.brushStroke == nil ? 0 : 2))
        var box = CGRect(x: minX - padding, y: minY - padding,
                         width: max(maxX - minX + padding * 2, 1),
                         height: max(maxY - minY + padding * 2, 1)).integral
        box.size.width = max(box.size.width, 1)
        box.size.height = max(box.size.height, 1)
        guard box.width <= DocumentLimits.maxSideExtent,
              box.height <= DocumentLimits.maxSideExtent,
              (draft.fill == nil && draft.brushStroke == nil || box.width * box.height <= DocumentLimits.maxSurfaceExtent)
        else { return nil }
        let normalized = draft.nodes.map { node in
            VectorPathNode(
                anchor: CGPoint(x: (node.anchor.x - box.minX) / box.width, y: (node.anchor.y - box.minY) / box.height),
                inHandle: CGPoint(x: (node.inHandle.x - box.minX) / box.width, y: (node.inHandle.y - box.minY) / box.height),
                outHandle: CGPoint(x: (node.outHandle.x - box.minX) / box.width, y: (node.outHandle.y - box.minY) / box.height)
            )
        }
        let style = LayerVectorPathStyle(
            mode: draft.mode,
            red: Double(draft.color.red),
            green: Double(draft.color.green),
            blue: Double(draft.color.blue),
            lineWidth: min(max(draft.lineWidth, 1), 5_000),
            nodes: normalized,
            closed: closed,
            subpathStarts: draft.subpathStarts,
            fill: draft.fill,
            brushStroke: draft.brushStroke,
            eraseStrokes: draft.eraseStrokes?.map { stroke in
                LayerVectorPathEraseStroke(
                    points: stroke.points.map {
                        CGPoint(x: ($0.x - box.minX) / box.width,
                                y: ($0.y - box.minY) / box.height)
                    },
                    diameterX: stroke.diameterX / box.width,
                    diameterY: stroke.diameterY / box.height
                )
            }
        )
        guard style.isValid else { return nil }
        return (style, box)
    }

    private func nextVectorPathName() -> String {
        nextPenResultName("Path")
    }

    /// Applies one continuous round sweep. Geometry updates while dragging are cheap; pixels and the thumbnail are
    /// rebuilt once on mouse-up, so a long erase does not repeatedly rasterize and split newly-created layers.
    private func erasePenPath(from start: CGPoint, to end: CGPoint, radius: CGFloat) {
        guard var gesture = penEraseGesture, radius.isFinite, radius > 0,
              let document,
              let index = document.layers.firstIndex(where: { $0.id == gesture.layerID })
        else { return }
        let layer = document.layers[index]
        guard let vectorPath = layer.liveVectorPath else { return }
        selectedPenNodeIndex = nil
        selectedPenHandle = nil

        if vectorPath.style.fill != nil {
            guard penFilledPathMayIntersectEraser(vectorPath.style, transform: layer.transform.unitToDocument,
                                                  start: start, end: end, radius: radius) else { return }
            let inverse = layer.transform.unitToDocument.inverted()
            let unitStart = start.applying(inverse)
            let unitEnd = end.applying(inverse)
            var style = vectorPath.style
            var strokes = style.eraseStrokes ?? []
            if let strokeIndex = gesture.fillStrokeIndex, strokes.indices.contains(strokeIndex) {
                if let last = strokes[strokeIndex].points.last, last != unitEnd {
                    let lastDocument = last.applying(layer.transform.unitToDocument)
                    if hypot(lastDocument.x - end.x, lastDocument.y - end.y) >= max(0.5, radius / 4) ||
                        strokes[strokeIndex].points.count == 1 {
                        strokes[strokeIndex].points.append(unitEnd)
                    } else {
                        strokes[strokeIndex].points[strokes[strokeIndex].points.count - 1] = unitEnd
                    }
                }
            } else {
                guard strokes.count < 1_000 else {
                    brushError = BrushStrokeError.pathTooComplex.localizedDescription
                    return
                }
                strokes.append(LayerVectorPathEraseStroke(
                    points: unitStart == unitEnd ? [unitStart] : [unitStart, unitEnd],
                    diameterX: radius * 2 / max(layer.transform.size.width, 1),
                    diameterY: radius * 2 / max(layer.transform.size.height, 1)
                ))
                gesture.fillStrokeIndex = strokes.count - 1
            }
            style.eraseStrokes = strokes
            guard style.isValid, let asset = layer.asset, let backing = PenBacking.image else {
                brushError = BrushStrokeError.pathTooComplex.localizedDescription
                return
            }
            self.document?.layers[index].asset = ImportedImage(
                image: backing, thumbnail: asset.thumbnail, name: asset.name
            )
            self.document?.layers[index].vectorPath = LayerVectorPath(style: style, image: backing)
            gesture.changed = true
            penEraseGesture = gesture
            return
        }

        guard let fragments = penPathFragmentsOutsideCapsule(
                nodes: vectorPath.style.nodes,
                closed: vectorPath.style.closed,
                subpathStarts: vectorPath.style.subpathStarts,
                transform: layer.transform.unitToDocument,
                start: start, end: end, radius: radius
              )
        else { return }

        guard !fragments.isEmpty else {
            // Clears any live mask that used this path as its source; a dangling source makes the project unloadable.
            finishDeletingLayer(gesture.layerID, baked: [:])
            gesture.changed = true
            penEraseGesture = gesture
            return
        }

        var nodes: [VectorPathNode] = []
        var starts: [Int] = []
        for fragment in fragments where fragment.count >= 2 {
            if !nodes.isEmpty { starts.append(nodes.count) }
            nodes.append(contentsOf: fragment)
        }
        var style = vectorPath.style
        style.mode = .line
        style.closed = false
        style.nodes = nodes
        style.subpathStarts = starts.isEmpty ? nil : starts
        guard style.isValid, let asset = layer.asset, let backing = PenBacking.image else {
            brushError = BrushStrokeError.pathTooComplex.localizedDescription
            return
        }

        // Hide the stale raster appearance during the gesture. The vector overlay remains live and the final
        // full-resolution appearance is generated once in `endPenErase`.
        self.document?.layers[index].asset = ImportedImage(
            image: backing, thumbnail: asset.thumbnail, name: asset.name
        )
        self.document?.layers[index].vectorPath = LayerVectorPath(style: style, image: backing)
        gesture.changed = true
        penEraseGesture = gesture
    }

    private func vectorPathImage(
        style: LayerVectorPathStyle,
        size: CGSize,
        appearanceScale: CGFloat = 1
    ) -> CGImage? {
        guard style.isValid else { return nil }
        guard style.fill != nil || style.brushStroke != nil else { return PenBacking.image }
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= DocumentLimits.maxSideExtent,
              size.height <= DocumentLimits.maxSideExtent,
              size.width * size.height <= DocumentLimits.maxSurfaceExtent
        else { return nil }

        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let drawSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let nodes = style.nodes(in: drawSize)

        if let fill = style.fill {
            context.setFillColor(CGColor(srgbRed: CGFloat(fill.red), green: CGFloat(fill.green),
                                         blue: CGFloat(fill.blue), alpha: 1))
            context.addPath(LayerVectorPathStyle.path(nodes: nodes, closed: true,
                                                      subpathStarts: style.subpathStarts))
            context.fillPath(using: .winding)
        }

        if let painted = style.brushStroke {
            var settings = BrushSettings()
            settings.diameter = max(1, CGFloat(painted.diameter) * appearanceScale)
            settings.hardness = CGFloat(painted.hardness)
            settings.opacity = CGFloat(painted.opacity)
            settings.red = CGFloat(painted.red)
            settings.green = CGFloat(painted.green)
            settings.blue = CGFloat(painted.blue)
            do {
                for range in penSubpathRanges(nodeCount: nodes.count,
                                              starts: style.subpathStarts ?? []) {
                    guard let points = flattenedPenPoints(
                        nodes: Array(nodes[range]), closed: style.closed,
                        flatness: max(0.2, min(0.75, settings.diameter / 32))
                    ) else { return nil }
                    // A piece whose points coincide (two anchors dragged together) has nothing to paint.
                    guard points.count >= 2 else { continue }
                    let blank = ImageLayer(name: "Path Stroke", blankSize: drawSize)
                    let stroke = try BrushStroke(layer: blank, mask: false, settings: settings,
                                                 canvas: drawSize, useGPU: false)
                    stroke.pixelLimit = width * height
                    try stroke.appendPolyline(points)
                    for patch in stroke.patches {
                        context.saveGState()
                        context.setBlendMode(.normal)
                        context.translateBy(x: patch.rect.minX, y: patch.rect.maxY)
                        context.scaleBy(x: 1, y: -1)
                        context.draw(patch.image, in: CGRect(origin: .zero, size: patch.rect.size))
                        context.restoreGState()
                    }
                }
            } catch { return nil }
        }
        for stroke in style.eraseStrokes ?? [] {
            drawVectorEraseStroke(stroke, in: context, size: drawSize)
        }
        return context.makeImage()
    }

    private func nextPenResultName(_ base: String) -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func editablePenPaths() -> [(ImageLayer, LayerVectorPath, [VectorPathNode])] {
        guard let document else { return [] }
        let visible = document.effectiveVisibleIDs
        return document.layers.reversed().compactMap { layer in
            guard (visible.contains(layer.id) || layer.id == activeLayerID),
                  let vectorPath = layer.liveVectorPath else { return nil }
            let transform = layer.transform.unitToDocument
            let nodes = vectorPath.style.nodes.map { node in
                VectorPathNode(anchor: node.anchor.applying(transform),
                               inHandle: node.inHandle.applying(transform),
                               outHandle: node.outHandle.applying(transform))
            }
            return (layer, vectorPath, nodes)
        }
    }
}

private nonisolated func drawVectorEraseStroke(
    _ stroke: LayerVectorPathEraseStroke,
    in context: CGContext,
    size: CGSize
) {
    guard stroke.isValid, let first = stroke.points.first else { return }
    let radiusX = CGFloat(stroke.diameterX) * size.width / 2
    let radiusY = CGFloat(stroke.diameterY) * size.height / 2
    guard radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0 else { return }
    let xScale = radiusX / radiusY
    func point(_ unit: CGPoint) -> CGPoint {
        CGPoint(x: unit.x * size.width / xScale, y: unit.y * size.height)
    }

    context.saveGState()
    context.setBlendMode(.clear)
    context.scaleBy(x: xScale, y: 1)
    if stroke.points.count == 1 {
        let center = point(first)
        context.fillEllipse(in: CGRect(x: center.x - radiusY, y: center.y - radiusY,
                                       width: radiusY * 2, height: radiusY * 2))
    } else {
        let path = CGMutablePath()
        path.move(to: point(first))
        for value in stroke.points.dropFirst() { path.addLine(to: point(value)) }
        context.setLineWidth(radiusY * 2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }
    context.restoreGState()
}

private nonisolated func penDocumentPoint(_ local: CGPoint, transform: LayerTransform) -> CGPoint {
    CGPoint(x: local.x / max(transform.size.width, 1),
            y: local.y / max(transform.size.height, 1)).applying(transform.unitToDocument)
}

private nonisolated func constrainedPenPoint(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
    let dx = point.x - origin.x
    let dy = point.y - origin.y
    let distance = hypot(dx, dy)
    guard distance > 0 else { return point }
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    return CGPoint(x: origin.x + cos(snapped) * distance, y: origin.y + sin(snapped) * distance)
}

private nonisolated func penSubpathRanges(nodeCount: Int, starts: [Int]) -> [Range<Int>] {
    guard nodeCount > 0, starts == starts.sorted(), Set(starts).count == starts.count,
          starts.allSatisfy({ $0 > 0 && $0 < nodeCount }) else { return [] }
    let boundaries = [0] + starts + [nodeCount]
    return zip(boundaries, boundaries.dropFirst()).map { $0..<$1 }
}

private nonisolated func penSegmentIndices(
    nodeCount: Int,
    closed: Bool,
    subpathStarts: [Int]?
) -> [Int] {
    let ranges = penSubpathRanges(nodeCount: nodeCount, starts: subpathStarts ?? [])
    var result: [Int] = []
    result.reserveCapacity(nodeCount)
    for range in ranges where range.count >= 2 {
        result.append(contentsOf: range.lowerBound..<(range.upperBound - 1))
        if closed { result.append(range.upperBound - 1) }
    }
    return result
}

private nonisolated func nearestPenNode(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    tolerance: CGFloat
) -> Int? {
    let limit = tolerance * tolerance
    return nodes.indices.min { squaredDistance(nodes[$0].anchor, point) < squaredDistance(nodes[$1].anchor, point) }
        .flatMap { squaredDistance(nodes[$0].anchor, point) <= limit ? $0 : nil }
}

private nonisolated func nearestPenHandle(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    tolerance: CGFloat
) -> (nodeIndex: Int, handle: PenHandle)? {
    var best: (nodeIndex: Int, handle: PenHandle, distance: CGFloat)?
    for (index, node) in nodes.enumerated() {
        for (handle, position) in [(PenHandle.incoming, node.inHandle), (.outgoing, node.outHandle)]
        where position != node.anchor {
            let distance = squaredDistance(position, point)
            if distance <= tolerance * tolerance, best == nil || distance < best!.distance {
                best = (index, handle, distance)
            }
        }
    }
    return best.map { ($0.nodeIndex, $0.handle) }
}

private nonisolated func nearestPenSegment(
    to point: CGPoint,
    in nodes: [VectorPathNode],
    closed: Bool,
    subpathStarts: [Int]? = nil,
    tolerance: CGFloat
) -> (segmentIndex: Int, t: CGFloat)? {
    guard nodes.count >= 2 else { return nil }
    var best: (segmentIndex: Int, t: CGFloat, distance: CGFloat)?
    for index in penSegmentIndices(nodeCount: nodes.count, closed: closed,
                                   subpathStarts: subpathStarts) {
        let first = nodes[index]
        let nextIndex = closed && index == nodes.count - 1 ? 0 : index + 1
        let second = nodes[nextIndex]
        let minX = min(min(first.anchor.x, first.outHandle.x), min(second.inHandle.x, second.anchor.x)) - tolerance
        let maxX = max(max(first.anchor.x, first.outHandle.x), max(second.inHandle.x, second.anchor.x)) + tolerance
        let minY = min(min(first.anchor.y, first.outHandle.y), min(second.inHandle.y, second.anchor.y)) - tolerance
        let maxY = max(max(first.anchor.y, first.outHandle.y), max(second.inHandle.y, second.anchor.y)) + tolerance
        guard point.x >= minX, point.x <= maxX, point.y >= minY, point.y <= maxY else { continue }
        let controlLength = hypot(first.outHandle.x - first.anchor.x, first.outHandle.y - first.anchor.y)
            + hypot(second.inHandle.x - first.outHandle.x, second.inHandle.y - first.outHandle.y)
            + hypot(second.anchor.x - second.inHandle.x, second.anchor.y - second.inHandle.y)
        let steps = min(64, max(4, Int(ceil(controlLength / max(tolerance, 0.25)))))
        var previous = first.anchor
        for step in 1...steps {
            let endT = CGFloat(step) / CGFloat(steps)
            let current = cubicPoint(first.anchor, first.outHandle, second.inHandle, second.anchor, t: endT)
            let vx = current.x - previous.x
            let vy = current.y - previous.y
            let lengthSquared = vx * vx + vy * vy
            let amount: CGFloat
            if lengthSquared > 0 {
                amount = min(max(((point.x - previous.x) * vx + (point.y - previous.y) * vy) / lengthSquared, 0), 1)
            } else {
                amount = 0
            }
            let projected = CGPoint(x: previous.x + vx * amount, y: previous.y + vy * amount)
            let distance = squaredDistance(projected, point)
            let t = (CGFloat(step - 1) + amount) / CGFloat(steps)
            if distance <= tolerance * tolerance, best == nil || distance < best!.distance {
                best = (index, t, distance)
            }
            previous = current
        }
    }
    return best.map { ($0.segmentIndex, $0.t) }
}

private nonisolated struct PenSegmentSplit {
    var nodes: [VectorPathNode]
    var subpathStarts: [Int]?
    let insertedIndex: Int
}

private nonisolated func splitPenSegment(
    nodes: [VectorPathNode],
    subpathStarts: [Int]?,
    segmentIndex: Int,
    t: CGFloat,
    closed: Bool
) -> PenSegmentSplit {
    let segments = penSegmentIndices(nodeCount: nodes.count, closed: closed,
                                     subpathStarts: subpathStarts)
    guard segments.contains(segmentIndex) else {
        return PenSegmentSplit(nodes: nodes, subpathStarts: subpathStarts,
                               insertedIndex: min(max(segmentIndex, 0), max(nodes.count - 1, 0)))
    }
    let nextIndex = closed && segmentIndex == nodes.count - 1 ? 0 : segmentIndex + 1
    var result = nodes
    let first = nodes[segmentIndex]
    let second = nodes[nextIndex]
    let a = lerp(first.anchor, first.outHandle, t)
    let b = lerp(first.outHandle, second.inHandle, t)
    let c = lerp(second.inHandle, second.anchor, t)
    let d = lerp(a, b, t)
    let e = lerp(b, c, t)
    let middle = lerp(d, e, t)
    result[segmentIndex].outHandle = a
    result[nextIndex].inHandle = c
    let node = VectorPathNode(anchor: middle, inHandle: d, outHandle: e)
    let insertedIndex: Int
    if nextIndex == 0 {
        result.append(node)
        insertedIndex = result.count - 1
    } else {
        result.insert(node, at: nextIndex)
        insertedIndex = nextIndex
    }
    let starts = subpathStarts?.map { $0 >= insertedIndex ? $0 + 1 : $0 }
    return PenSegmentSplit(nodes: result, subpathStarts: starts, insertedIndex: insertedIndex)
}

private nonisolated struct PenCubic {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint

    func applying(_ transform: CGAffineTransform) -> PenCubic {
        PenCubic(start: start.applying(transform), control1: control1.applying(transform),
                 control2: control2.applying(transform), end: end.applying(transform))
    }
}

private nonisolated func penFilledPathMayIntersectEraser(
    _ style: LayerVectorPathStyle,
    transform: CGAffineTransform,
    start: CGPoint,
    end: CGPoint,
    radius: CGFloat
) -> Bool {
    let nodes = style.nodes.map { node in
        VectorPathNode(anchor: node.anchor.applying(transform),
                       inHandle: node.inHandle.applying(transform),
                       outHandle: node.outHandle.applying(transform))
    }
    let bounds = LayerVectorPathStyle.path(nodes: nodes, closed: true,
                                           subpathStarts: style.subpathStarts).boundingBoxOfPath
    let eraser = CGRect(x: min(start.x, end.x) - radius, y: min(start.y, end.y) - radius,
                        width: abs(end.x - start.x) + radius * 2,
                        height: abs(end.y - start.y) + radius * 2)
    return !bounds.isNull && bounds.intersects(eraser)
}

/// Removes the portions covered by one continuous round eraser sweep. Nil means the sweep missed. Disconnected
/// results remain subpaths of the same vector object, and retained pieces remain cubic instead of degrading into
/// dense polylines after repeated erasing.
private nonisolated func penPathFragmentsOutsideCapsule(
    nodes: [VectorPathNode],
    closed: Bool,
    subpathStarts: [Int]?,
    transform: CGAffineTransform,
    start brushStart: CGPoint,
    end brushEnd: CGPoint,
    radius: CGFloat
) -> [[VectorPathNode]]? {
    guard nodes.count >= 2, radius.isFinite, radius > 0 else { return nil }
    var result: [[VectorPathNode]] = []
    var erased = false
    for range in penSubpathRanges(nodeCount: nodes.count, starts: subpathStarts ?? []) {
        let subpath = Array(nodes[range])
        if let fragments = penSinglePathFragmentsOutsideCapsule(
            nodes: subpath, closed: closed, transform: transform,
            start: brushStart, end: brushEnd, radius: radius
        ) {
            erased = true
            result.append(contentsOf: fragments)
        } else {
            result.append(subpath)
        }
    }
    return erased ? result : nil
}

private nonisolated func penSinglePathFragmentsOutsideCapsule(
    nodes: [VectorPathNode],
    closed: Bool,
    transform: CGAffineTransform,
    start brushStart: CGPoint,
    end brushEnd: CGPoint,
    radius: CGFloat
) -> [[VectorPathNode]]? {
    let radiusSquared = radius * radius
    var pieces: [(curve: PenCubic, outside: Bool)] = []
    var erased = false
    let segmentCount = closed ? nodes.count : nodes.count - 1

    for index in 0..<segmentCount {
        let first = nodes[index]
        let second = nodes[(index + 1) % nodes.count]
        let curve = PenCubic(start: first.anchor, control1: first.outHandle,
                             control2: second.inHandle, end: second.anchor)
        let classified = penCubicPiecesOutsideCapsule(
            curve, transform: transform, start: brushStart, end: brushEnd,
            radius: radius, radiusSquared: radiusSquared
        )
        erased = erased || classified.contains { !$0.outside }
        pieces.append(contentsOf: classified)
    }
    guard erased else { return nil }

    // A closed path has no natural beginning. Start just after an erased piece so a retained run that crosses
    // the old first anchor is emitted as one path instead of two artificial fragments.
    if closed, let gap = pieces.firstIndex(where: { !$0.outside }) {
        let next = gap + 1
        pieces = (next < pieces.count ? Array(pieces[next...]) : []) + Array(pieces[...gap])
    }

    var fragments: [[VectorPathNode]] = []
    var current: [VectorPathNode] = []
    func finishFragment() {
        let documentNodes = current.map { node in
            VectorPathNode(anchor: node.anchor.applying(transform),
                           inHandle: node.inHandle.applying(transform),
                           outHandle: node.outHandle.applying(transform))
        }
        let length = zip(documentNodes, documentNodes.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + hypot(pair.0.outHandle.x - pair.0.anchor.x,
                            pair.0.outHandle.y - pair.0.anchor.y)
                + hypot(pair.1.inHandle.x - pair.0.outHandle.x,
                        pair.1.inHandle.y - pair.0.outHandle.y)
                + hypot(pair.1.anchor.x - pair.1.inHandle.x,
                        pair.1.anchor.y - pair.1.inHandle.y)
        }
        if current.count >= 2, length >= 0.5 {
            fragments.append(current)
        }
        current.removeAll(keepingCapacity: true)
    }
    for piece in pieces {
        guard piece.outside else { finishFragment(); continue }
        if current.isEmpty {
            current.append(VectorPathNode(anchor: piece.curve.start))
        } else if squaredDistance(current[current.count - 1].anchor, piece.curve.start) > 0.000_000_000_001 {
            finishFragment()
            current.append(VectorPathNode(anchor: piece.curve.start))
        }
        current[current.count - 1].outHandle = piece.curve.control1
        current.append(VectorPathNode(anchor: piece.curve.end, inHandle: piece.curve.control2))
    }
    finishFragment()
    return fragments
}

private nonisolated func penCubicPiecesOutsideCapsule(
    _ curve: PenCubic,
    transform: CGAffineTransform,
    start: CGPoint,
    end: CGPoint,
    radius: CGFloat,
    radiusSquared: CGFloat
) -> [(curve: PenCubic, outside: Bool)] {
    let brushBounds = CGRect(
        x: min(start.x, end.x) - radius,
        y: min(start.y, end.y) - radius,
        width: abs(end.x - start.x) + radius * 2,
        height: abs(end.y - start.y) + radius * 2
    )
    var intervals: [(from: CGFloat, to: CGFloat, outside: Bool)] = []

    func append(_ part: PenCubic, from: CGFloat, to: CGFloat, depth: Int) {
        let document = part.applying(transform)
        let points = [document.start, document.control1, document.control2, document.end]
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        if maxX < brushBounds.minX || minX > brushBounds.maxX ||
            maxY < brushBounds.minY || minY > brushBounds.maxY {
            intervals.append((from, to, true))
            return
        }
        let inside = points.map { squaredDistanceToSegment($0, from: start, to: end) <= radiusSquared }
        if inside.allSatisfy({ $0 }) {
            intervals.append((from, to, false))
            return
        }
        let length = hypot(document.control1.x - document.start.x,
                           document.control1.y - document.start.y)
            + hypot(document.control2.x - document.control1.x,
                    document.control2.y - document.control1.y)
            + hypot(document.end.x - document.control2.x,
                    document.end.y - document.control2.y)
        if length <= max(0.25, min(1, radius / 8)) || depth >= 16 {
            let middle = cubicPoint(document.start, document.control1, document.control2,
                                    document.end, t: 0.5)
            intervals.append((from, to,
                              squaredDistanceToSegment(middle, from: start, to: end) > radiusSquared))
            return
        }
        let split = splitPenCubic(part, at: 0.5)
        let middle = (from + to) / 2
        append(split.left, from: from, to: middle, depth: depth + 1)
        append(split.right, from: middle, to: to, depth: depth + 1)
    }
    append(curve, from: 0, to: 1, depth: 0)

    var merged: [(from: CGFloat, to: CGFloat, outside: Bool)] = []
    for interval in intervals {
        if let last = merged.indices.last, merged[last].outside == interval.outside {
            merged[last].to = interval.to
        } else {
            merged.append(interval)
        }
    }
    let documentCurve = curve.applying(transform)
    for index in 0..<max(0, merged.count - 1) where merged[index].outside != merged[index + 1].outside {
        var low = (merged[index].from + merged[index].to) / 2
        var high = (merged[index + 1].from + merged[index + 1].to) / 2
        let lowOutside = merged[index].outside
        for _ in 0..<18 {
            let middle = (low + high) / 2
            let point = cubicPoint(documentCurve.start, documentCurve.control1,
                                   documentCurve.control2, documentCurve.end, t: middle)
            let outside = squaredDistanceToSegment(point, from: start, to: end) > radiusSquared
            if outside == lowOutside { low = middle } else { high = middle }
        }
        let boundary = (low + high) / 2
        merged[index].to = boundary
        merged[index + 1].from = boundary
    }
    return merged.map { (penCubicSubcurve(curve, from: $0.from, to: $0.to), $0.outside) }
}

private nonisolated func penCubicSubcurve(_ curve: PenCubic, from start: CGFloat, to end: CGFloat) -> PenCubic {
    let left = end >= 1 ? curve : splitPenCubic(curve, at: end).left
    guard start > 0 else { return left }
    return splitPenCubic(left, at: min(1, start / end)).right
}

private nonisolated func splitPenCubic(_ curve: PenCubic, at amount: CGFloat) -> (left: PenCubic, right: PenCubic) {
    let a = lerp(curve.start, curve.control1, amount)
    let b = lerp(curve.control1, curve.control2, amount)
    let c = lerp(curve.control2, curve.end, amount)
    let d = lerp(a, b, amount)
    let e = lerp(b, c, amount)
    let middle = lerp(d, e, amount)
    return (
        PenCubic(start: curve.start, control1: a, control2: d, end: middle),
        PenCubic(start: middle, control1: e, control2: c, end: curve.end)
    )
}

private nonisolated func cubicPoint(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    t: CGFloat
) -> CGPoint {
    let oneMinusT = 1 - t
    let a = oneMinusT * oneMinusT * oneMinusT
    let b = 3 * oneMinusT * oneMinusT * t
    let c = 3 * oneMinusT * t * t
    let d = t * t * t
    return CGPoint(
        x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
}

/// Flattens the Pen's cubic segments for the brush engine. A path that exceeds the cap is rejected rather than
/// truncated: joining distant points after truncation could paint an unrelated slash across the document.
private nonisolated func flattenedPenPoints(
    nodes: [VectorPathNode], closed: Bool, flatness: CGFloat
) -> [CGPoint]? {
    guard nodes.count >= 2, flatness.isFinite, flatness > 0 else { return nil }
    let pointLimit = 250_000
    var result = [nodes[0].anchor]
    var exceededLimit = false
    let segmentCount = closed ? nodes.count : nodes.count - 1

    func distanceToChord(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squared = dx * dx + dy * dy
        guard squared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let amount = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squared, 0), 1)
        return hypot(point.x - start.x - amount * dx, point.y - start.y - amount * dy)
    }

    func appendCurve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, depth: Int) {
        guard !exceededLimit else { return }
        let error = max(distanceToChord(p1, from: p0, to: p3),
                        distanceToChord(p2, from: p0, to: p3))
        if error <= flatness || depth >= 12 {
            guard result.last == p3 || result.count < pointLimit else { exceededLimit = true; return }
            if result.last != p3 { result.append(p3) }
            return
        }
        let p01 = lerp(p0, p1, 0.5)
        let p12 = lerp(p1, p2, 0.5)
        let p23 = lerp(p2, p3, 0.5)
        let p012 = lerp(p01, p12, 0.5)
        let p123 = lerp(p12, p23, 0.5)
        let midpoint = lerp(p012, p123, 0.5)
        appendCurve(p0, p01, p012, midpoint, depth: depth + 1)
        appendCurve(midpoint, p123, p23, p3, depth: depth + 1)
    }

    for index in 0..<segmentCount {
        let first = nodes[index]
        let second = nodes[(index + 1) % nodes.count]
        appendCurve(first.anchor, first.outHandle, second.inHandle, second.anchor, depth: 0)
        if exceededLimit { return nil }
    }
    return result
}

private nonisolated func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x, dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}

private nonisolated func squaredDistanceToSegment(
    _ point: CGPoint,
    from start: CGPoint,
    to end: CGPoint
) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return squaredDistance(point, start) }
    let amount = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
    return squaredDistance(point, CGPoint(x: start.x + dx * amount, y: start.y + dy * amount))
}

nonisolated enum PenBacking {
    static let image: CGImage? = {
        guard let context = try? BrushRaster.context(width: 1, height: 1, mask: false) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
    }()
}

private nonisolated func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x + (rhs.x - lhs.x) * t, y: lhs.y + (rhs.y - lhs.y) * t)
}
